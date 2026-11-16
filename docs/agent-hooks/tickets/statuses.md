# Statuses and workflow tags

What the default statuses and the two workflow tags mean, and when an agent
changes them. The CLI enforces none of this: any status may follow any other,
and dependencies never veto a change. A tracker may configure other statuses
in its `zwanenzang.toml`; then the project's instructions say what they mean.

## Statuses

- `todo`: not started.
- `next`: the human is on it, or it can be started now.
- `wait`: waiting on something. With `needs_human`, on the human.
- `agnt`: an agent is working on it autonomously.
- `revw`: ready for the human's review; always also tagged `needs_human`.
- `done`: finished. Set by the human, or by an agent only after confirming
  the merge request was merged or on the human's explicit instruction.
- `cncl`: cancelled.

## Workflow tags

Two tags carry workflow; every other tag only classifies.

- `ready_for_agent`: standing permission for an agent to pick the ticket up
  on its own. Only the human adds or removes it. It stays through `agnt`,
  `wait` and `revw`.
- `needs_human`: an agent is waiting on the human, with `wait` or `revw`.

An agent may add or remove classification tags. It adds and removes
`needs_human` as described below, and never touches `ready_for_agent`.

## Advancing a ticket

A request that is only a ticket reference means: sync, read the ticket's
documents and relevant history, and advance it to the next actionable step,
not merely report its status. Limits stated in the request, such as
investigation only or read only, still apply. Such a request does not
authorize merging, bypassing review, or starting other agents.

- Ask the human about unresolved decisions that materially affect scope,
  human-facing behavior, compatibility or explicit project constraints. Do
  not invent acceptance, and do not silently override a restriction because
  it looks stale.
- Choose ordinary implementation details within the agreed scope yourself;
  record the consequential ones and test them. An investigation need not
  settle every technical detail before implementation can start.
- When the human resolves a blocker, update the brief and continue with the
  next authorized step without waiting for another start signal. `wait` is
  not by itself an instruction to stay idle: check its recorded unblock
  condition.
- If uncertainty remains, ask one focused question with a recommendation,
  and say what can proceed meanwhile.

## Interactive and autonomous work

The rules for `agnt` and `ready_for_agent` govern autonomous work only.

- Interactive: the human is in the conversation and directing it. The agent
  may read and write any ticket the human points it to, tagged or not. It
  changes status only when the human asks; it does not set `agnt` and does
  not hand back with `revw`, since the human is right there.
- Autonomous: the agent carries a ticket without the human in the
  conversation, as in a batch run, or after the human handed the work over
  and left ("implement it, I'll review the merge request"). It works only on
  tickets tagged `ready_for_agent`, or on one the human handed over that way;
  the handover counts as the permission.

In autonomous work:

1. Whoever starts the work sets `agnt` just before starting it: the agent
   itself, or an orchestrator for the ticket of each agent it launches.
   `agnt` records that the work is running. It does not request work; the
   tag or the handover does.
2. The agent ends by handing back: `revw` plus `needs_human` when the work
   is ready for review, with the merge request recorded on the ticket, or
   `wait` plus `needs_human` when it needs an answer, with the question in a
   comment.
3. When the human answers, the agent removes `needs_human` as it resumes,
   setting `agnt` again if it resumes autonomously.

`agnt` is a status, not a lock. Preventing two agents from taking the same
ticket, and recovering a ticket left in `agnt` by a session that died, are
for whatever orchestrates the agents, not for these rules.

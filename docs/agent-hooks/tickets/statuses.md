# Statuses and workflow tags

What the default statuses and the two workflow tags mean, and when an agent
changes them. The CLI enforces none of this: any status may follow any other,
and dependencies never veto a change. The one exception is a ticket tagged
`PROJ`, a project: see `zz agent-hooks show-document tickets/writing`. A
tracker may configure other statuses in its `zwanenzang.toml`; then the
project's instructions say what they mean.

## Statuses

- `todo`: not started.
- `next`: the human is on it, alone or investigating it with an agent, or
  it can be started now.
- `wait`: waiting on something. With `needs_human`, on the human.
- `agnt`: an agent is doing the work, interactively or autonomously.
- `revw`: ready for the human's review; always also tagged `needs_human`.
- `done`: finished. Set by the human, or by an agent only after confirming
  the merge request was merged or on the human's explicit instruction.
- `cncl`: cancelled.

## Workflow tags

Two tags carry workflow; every other tag only classifies.

- `ready_for_agent`: standing permission for an agent to pick the ticket up
  on its own; interactive work needs no tag. Only the human adds or removes
  it. It stays through `agnt`, `wait` and `revw`.
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

Status shows where the work is, in either mode.

- Interactive: the human is in the conversation and directing it. The agent
  may read and write any ticket the human points it to, tagged or not.
- Autonomous: the agent carries a ticket without the human in the
  conversation, as in a batch run, or after the human handed the work over
  and left ("implement it, I'll review the merge request"). It works only on
  tickets tagged `ready_for_agent`, or on one the human handed over that way;
  the handover counts as the permission.

In either mode:

1. Investigating or grilling a ticket with the human sets `next`. Writing
   its brief or notes meanwhile keeps it `next`.
2. Starting the implementation sets `agnt`: at `swl start`, or at the first
   code change where there is no workspace. An orchestrator sets it for the
   ticket of each agent it launches to implement, just before launching it;
   launching one only to investigate does not set it. `agnt`
   records that the work is running. It does not request work; the tag or
   the handover does.
3. A question asked in the conversation does not change status.
4. A published merge request waiting on the human is `revw` plus
   `needs_human`, with the merge request recorded on the ticket.
5. Resuming from `revw` or `wait` removes `needs_human` and sets `agnt`;
   after republishing, the ticket goes back to `revw` plus `needs_human`.

An autonomous agent ends by handing back: `revw` plus `needs_human` when the
work is ready for review, or `wait` plus `needs_human` when it needs an
answer, with the question in a comment. `wait` plus `needs_human` is only
for such a question left on the ticket, never for one asked in the
conversation.

`agnt` is a status, not a lock. Preventing two agents from taking the same
ticket, and recovering a ticket left in `agnt` by a session that died, are
for whatever orchestrates the agents, not for these rules.

//! Live writes: replay everything under the lock, build each new event with
//! the hybrid clock, validate it with the same [`apply`] replay uses, and
//! append only what is accepted and changes derived state.

use std::collections::{BTreeMap, BTreeSet};

use crate::clock::{Clock, format_ts, leaps_too_far, next_id};
use crate::error::{Error, Result};
use crate::event::{ActorData, Event, Op};
use crate::names::valid_actor_name;
use crate::replay::{Replay, replay};
use crate::state::{RejectCode, Rejection, apply};
use crate::store::{Tracker, blob_name};
use crate::ulid::Ulid;

/// The entity a planned event names.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Target {
    Entity(Ulid),
    /// The ticket created by an earlier `create` in the same plan. A
    /// `create` itself always names its own id, whatever its target.
    Created,
    /// The ticket created by the plan's `create` number `n`, counting the
    /// plan's `create` operations from 0.
    Nth(usize),
}

/// What a command wants written, computed from the replayed state.
#[derive(Debug, Default)]
pub struct Plan {
    /// Events to write, in order.
    pub ops: Vec<(Target, Op)>,
    /// Texts the operations refer to by blob name.
    pub blobs: Vec<String>,
    /// Ticket references resolved when the events are built: the `to` of
    /// the `relate`, `unrelate` or `parent` operation at index `i` of `ops`
    /// becomes the entity of the target. A plan can so relate tickets it
    /// creates itself, whose ids are not known until they are written.
    pub refs: Vec<(usize, Target)>,
}

/// How [`Tracker::write_with`] writes.
#[derive(Debug, Clone, Copy, Default)]
pub struct WriteOptions<'a> {
    /// Display name for an actor that has not declared one yet; see
    /// [`Tracker::write`].
    pub actor_name: Option<&'a str>,
    /// Write as a new actor with a fresh id instead of this clone's actor.
    /// The new actor declares `actor_name`, which is then required.
    pub new_actor: bool,
    /// Validate and build every event, but write nothing.
    pub dry_run: bool,
}

#[derive(Debug)]
pub struct Written {
    /// Every line written, including an `actor` declaration.
    pub events: Vec<Event>,
    /// Ids of the written events that came from the plan, in plan order;
    /// planned operations that changed nothing are absent.
    pub planned: Vec<Ulid>,
    /// State after the write.
    pub replay: Replay,
}

impl Written {
    pub fn written(&self) -> bool {
        !self.events.is_empty()
    }

    /// The last written event that came from the plan.
    pub fn primary(&self) -> Option<&Event> {
        let id = self.planned.last()?;
        self.events.iter().find(|e| e.id == *id)
    }
}

/// The entity a target names, given the tickets created so far.
fn resolve(target: Target, created: &[Ulid]) -> Result<Ulid> {
    match target {
        Target::Entity(e) => Some(e),
        Target::Created => created.last().copied(),
        Target::Nth(n) => created.get(n).copied(),
    }
    .ok_or_else(|| Error::InvalidArgument("plan names a created ticket before creating it".into()))
}

impl Tracker {
    /// Replays the tracker without taking the lock.
    pub fn load(&self) -> Result<Replay> {
        let lines = self.read_logs()?;
        let blobs = self.blob_names()?;
        Ok(replay(&self.config, blobs, &lines))
    }

    /// Performs one mutating command. `plan` sees the replayed state and
    /// returns what to write. Either every planned event that changes state
    /// is written, or, if any is refused, nothing is.
    pub fn write(
        &self,
        clock: &mut dyn Clock,
        actor_name: Option<&str>,
        plan: impl FnOnce(&Replay) -> Result<Plan>,
    ) -> Result<Written> {
        let opts = WriteOptions {
            actor_name,
            ..WriteOptions::default()
        };
        self.write_with(clock, opts, plan, |_| Ok(()))
    }

    /// [`Tracker::write`] with options. `before_append` runs under the lock
    /// once every event has been accepted, before any blob or line is
    /// written; if it fails, nothing is written. It is not called on a dry
    /// run, nor when there is nothing to write.
    pub fn write_with(
        &self,
        clock: &mut dyn Clock,
        opts: WriteOptions<'_>,
        plan: impl FnOnce(&Replay) -> Result<Plan>,
        before_append: impl FnOnce(&[Event]) -> Result<()>,
    ) -> Result<Written> {
        let _lock = self.lock()?;
        let mut rp = self.load()?;
        let actor = if opts.new_actor {
            if opts.actor_name.is_none() {
                return Err(Error::InvalidArgument("a new actor needs a name".into()));
            }
            // Like a clone's actor id: fresh, not from the event clock.
            next_id(clock, None)
        } else if opts.dry_run {
            // A dry run must not create this clone's actor id either.
            match self.actor_id_opt(false, clock)? {
                Some(a) => a,
                None => next_id(clock, None),
            }
        } else {
            self.actor_id(true, clock)?
        };
        let plan = plan(&rp)?;

        let mut state = rp.state.clone();
        let pending: BTreeSet<String> = plan.blobs.iter().map(|t| blob_name(t)).collect();
        state.blobs.extend(pending.iter().cloned());

        // (operation, index in the plan, or None for the actor declaration)
        let mut ops: Vec<(Target, Op, Option<usize>)> = Vec::new();
        let declared = state.actors.get(&actor).is_some_and(|a| a.name.is_some());
        if !declared && !plan.ops.is_empty() {
            let name = match opts.actor_name {
                Some(n) => {
                    if !valid_actor_name(n) {
                        return Err(Error::InvalidArgument(format!("invalid actor name {n:?}")));
                    }
                    n.to_string()
                }
                None => std::env::var("USER")
                    .ok()
                    .filter(|n| valid_actor_name(n))
                    .unwrap_or_else(|| "unknown".to_string()),
            };
            ops.push((
                Target::Entity(state.root),
                Op::Actor(ActorData { name }),
                None,
            ));
        }
        ops.extend(
            plan.ops
                .into_iter()
                .enumerate()
                .map(|(i, (e, o))| (e, o, Some(i))),
        );
        let refs: BTreeMap<usize, Target> = plan.refs.into_iter().collect();

        let mut highest = rp.highest_seen;
        let mut events = Vec::new();
        let mut planned = Vec::new();
        let mut created: Vec<Ulid> = Vec::new();
        for (target, mut op, index) in ops {
            let id = next_id(clock, highest);
            let ts = format_ts(clock.now_ms());
            if let Some(t) = index.and_then(|i| refs.get(&i)) {
                let to = resolve(*t, &created)?;
                match &mut op {
                    Op::Relate(d) | Op::Unrelate(d) => d.to = to,
                    Op::Parent(d) => d.to = Some(to),
                    _ => {
                        return Err(Error::InvalidArgument(format!(
                            "plan resolves a ticket reference in a {} operation",
                            op.name()
                        )));
                    }
                }
            }
            let entity = match &op {
                Op::Create(_) => {
                    created.push(id);
                    id
                }
                _ => resolve(target, &created)?,
            };
            let ev = Event {
                id,
                actor,
                parent: highest,
                ts,
                entity,
                op,
            };
            let anchor = highest.map_or(state.root, |h| h.max(state.root));
            if leaps_too_far(anchor, id) {
                return Err(Error::Rejected(Rejection {
                    code: RejectCode::IdOutOfRange,
                    message: format!(
                        "id {id} is more than 1000 years after {anchor}, the newest id seen; \
                         is the clock set right?"
                    ),
                }));
            }
            let mut trial = state.clone();
            let applied = apply(&mut trial, &ev).map_err(Error::Rejected)?;
            if let Some(lost) = applied.lost {
                return Err(Error::Rejected(Rejection {
                    code: RejectCode::StaleDocBase,
                    message: format!(
                        "document {:?}: base {} is not the current version {}",
                        lost.name,
                        lost.base.map_or("null".into(), |b| b.to_string()),
                        lost.current.map_or("null".into(), |b| b.to_string()),
                    ),
                }));
            }
            if !applied.changed {
                continue;
            }
            state = trial;
            highest = Some(id);
            if index.is_some() {
                planned.push(id);
            }
            events.push(ev);
        }
        if planned.is_empty() {
            // Nothing but a possible actor declaration: write nothing.
            return Ok(Written {
                events: Vec::new(),
                planned,
                replay: rp,
            });
        }
        if opts.dry_run {
            rp.state = state;
            rp.events.extend(events.iter().cloned());
            rp.highest_seen = highest;
            return Ok(Written {
                events,
                planned,
                replay: rp,
            });
        }
        before_append(&events)?;

        // Blobs first, so a crash never leaves an event naming a missing blob.
        let used: BTreeSet<&str> = events
            .iter()
            .filter_map(|e| match &e.op {
                Op::Doc(d) => Some(d.blob.as_str()),
                Op::Comment(d) => d.blob.as_deref(),
                _ => None,
            })
            .collect();
        for text in &plan.blobs {
            if used.contains(blob_name(text).as_str()) {
                self.put_blob(text, clock)?;
            }
        }
        let lines: Vec<String> = events.iter().map(Event::to_line).collect();
        self.append_lines(actor, &lines)?;

        state.blobs = self.blob_names()?;
        rp.state = state;
        rp.events.extend(events.iter().cloned());
        rp.highest_seen = highest;
        Ok(Written {
            events,
            planned,
            replay: rp,
        })
    }
}

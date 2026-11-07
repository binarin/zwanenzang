//! Live writes: replay everything under the lock, build each new event with
//! the hybrid clock, validate it with the same [`apply`] replay uses, and
//! append only what is accepted and changes derived state.

use std::collections::BTreeSet;

use crate::clock::{Clock, format_ts, next_id};
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
}

/// What a command wants written, computed from the replayed state.
#[derive(Debug, Default)]
pub struct Plan {
    /// Events to write, in order.
    pub ops: Vec<(Target, Op)>,
    /// Texts the operations refer to by blob name.
    pub blobs: Vec<String>,
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
        let _lock = self.lock()?;
        let actor = self.actor_id(true, clock)?;
        let mut rp = self.load()?;
        let plan = plan(&rp)?;

        let mut state = rp.state.clone();
        let pending: BTreeSet<String> = plan.blobs.iter().map(|t| blob_name(t)).collect();
        state.blobs.extend(pending.iter().cloned());

        let mut ops: Vec<(Target, Op, bool)> = Vec::new();
        let declared = state.actors.get(&actor).is_some_and(|a| a.name.is_some());
        if !declared && !plan.ops.is_empty() {
            let name = match actor_name {
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
                false,
            ));
        }
        ops.extend(plan.ops.into_iter().map(|(e, o)| (e, o, true)));

        let mut highest = rp.highest_seen;
        let mut events = Vec::new();
        let mut planned = Vec::new();
        let mut created = None;
        for (target, op, from_plan) in ops {
            let id = next_id(clock, highest);
            let ts = format_ts(clock.now_ms());
            let entity = match (&op, target) {
                (Op::Create(_), _) => {
                    created = Some(id);
                    id
                }
                (_, Target::Entity(e)) => e,
                (_, Target::Created) => created.ok_or_else(|| {
                    Error::InvalidArgument("plan names a created ticket before creating it".into())
                })?,
            };
            let ev = Event {
                id,
                actor,
                parent: highest,
                ts,
                entity,
                op,
            };
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
            if from_plan {
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

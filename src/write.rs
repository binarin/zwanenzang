//! Live writes: replay everything under the lock, build each new event with
//! the hybrid clock, validate it with the same [`apply`] replay uses, append
//! only what is accepted and changes derived state, commit it, and sync.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

use crate::clock::{Clock, format_ts, leaps_too_far, next_id};
use crate::error::{Error, Result};
use crate::event::{ActorData, CreateData, Event, Op, TextTo};
use crate::git::Repo;
use crate::replay::{Replay, replay};
use crate::state::{RejectCode, Rejection, apply};
use crate::store::{DEFAULT_ACTOR_KEY, Tracker, blob_name, lock_repo};
use crate::sync::SyncReport;
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
    /// the `relate`, `unrelate`, `depend`, `undepend` or `parent` operation at index `i` of `ops`
    /// becomes the entity of the target. A plan can so relate tickets it
    /// creates itself, whose ids are not known until they are written.
    pub refs: Vec<(usize, Target)>,
}

/// How [`Tracker::write_with`] writes.
#[derive(Debug, Clone, Copy, Default)]
pub struct WriteOptions<'a> {
    /// The identity of the write, recorded as `as` on every event it
    /// writes; see [`Tracker::write`].
    pub actor_name: Option<&'a str>,
    /// Write as a new writer with a fresh id instead of this clone's
    /// writer. `actor_name` is then required.
    pub new_actor: bool,
    /// Validate and build every event, but write nothing. Needs no
    /// identity.
    pub dry_run: bool,
    /// The commit message, instead of one naming the main event.
    pub message: Option<&'a str>,
}

#[derive(Debug)]
pub struct Written {
    /// Every line written, including an `actor` declaration.
    pub events: Vec<Event>,
    /// The identity the events were written as; `None` only for a dry run
    /// or a write of nothing that named none.
    pub identity: Option<String>,
    /// Ids of the written events that came from the plan, in plan order;
    /// planned operations that changed nothing are absent.
    pub planned: Vec<Ulid>,
    /// One event id per plan operation; `None` for a no-op.
    pub outcomes: Vec<Option<Ulid>>,
    /// State after the write and the sync.
    pub replay: Replay,
    /// What the sync after the write did; `None` when nothing was written.
    pub sync: Option<SyncReport>,
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
    ///
    /// Every event carries the write's identity: `actor_name`, else the
    /// clone's `zwanenzang.defaultActor`. A write that changes anything
    /// with neither is refused, as is an identity the tracker does not
    /// accept.
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
        self.write_with(clock, opts, plan, |_| Ok(Vec::new()))
    }

    /// [`Tracker::write`] with options. `before_append` runs under the lock
    /// once every event has been accepted, before any blob or line is
    /// written; if it fails, nothing is written. It returns the further
    /// files it wrote, relative to the root, to commit with the events. It
    /// is not called on a dry run, nor when there is nothing to write.
    pub fn write_with(
        &self,
        clock: &mut dyn Clock,
        opts: WriteOptions<'_>,
        plan: impl FnOnce(&Replay) -> Result<Plan>,
        before_append: impl FnOnce(&[Event]) -> Result<Vec<PathBuf>>,
    ) -> Result<Written> {
        let repo = self.repo()?;
        let _lock = lock_repo(&repo)?;
        let (mut w, files) = self.write_locked(&repo, clock, opts, plan, before_append)?;
        if !w.written() || opts.dry_run {
            return Ok(w);
        }
        let actor = w.events[0].actor;
        let message = match opts.message {
            Some(m) => m.to_string(),
            None => commit_message(self, &w),
        };
        let mut paths = vec![PathBuf::from("events"), PathBuf::from("blobs")];
        paths.extend(files);
        repo.commit(
            &paths,
            &message,
            &crate::sync::identity(actor, w.identity.clone()),
        )?;
        // Numbers the sync publishes are part of this write.
        let identity = w.identity.clone();
        let report = self.sync_locked(&repo, clock, identity.as_deref())?;
        w.replay = self.load()?;
        w.sync = Some(report);
        Ok(w)
    }

    /// Builds, validates and appends under a lock the caller holds; no
    /// commit.
    pub(crate) fn write_locked(
        &self,
        repo: &Repo,
        clock: &mut dyn Clock,
        opts: WriteOptions<'_>,
        plan: impl FnOnce(&Replay) -> Result<Plan>,
        before_append: impl FnOnce(&[Event]) -> Result<Vec<PathBuf>>,
    ) -> Result<(Written, Vec<PathBuf>)> {
        let mut rp = self.load()?;
        let identity = self.write_identity(repo, opts.actor_name)?;
        let actor = if opts.new_actor {
            if opts.actor_name.is_none() {
                return Err(Error::InvalidArgument("a new actor needs a name".into()));
            }
            // Like a clone's actor id: fresh, not from the event clock.
            next_id(clock, None)
        } else if opts.dry_run {
            // A dry run must not create this clone's actor id either.
            match self.actor_in(repo, false, clock)? {
                Some(a) => a,
                None => next_id(clock, None),
            }
        } else {
            self.actor_in(repo, true, clock)?.expect("created")
        };
        let plan = plan(&rp)?;

        let mut outcomes = vec![None; plan.ops.len()];
        let mut state = rp.state.clone();
        let pending: BTreeSet<String> = plan.blobs.iter().map(|t| blob_name(t)).collect();
        state.blobs.extend(pending.iter().cloned());

        // (operation, index in the plan, or None for the actor declaration)
        let mut ops: Vec<(Target, Op, Option<usize>)> = Vec::new();
        let declared = state.actors.get(&actor).is_some_and(|a| a.name.is_some());
        // A writer's first write still declares a display name, its
        // identity then, so builds that predate `as` show a name.
        if !declared
            && !plan.ops.is_empty()
            && let Some(name) = &identity
        {
            ops.push((
                Target::Entity(state.root),
                Op::Actor(ActorData { name: name.clone() }),
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
                    Op::Relate(d) | Op::Unrelate(d) | Op::Depend(d) | Op::Undepend(d) => d.to = to,
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
                identity: identity.clone(),
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
            if let Op::Status(TextTo { to: status }) | Op::Create(CreateData { status, .. }) =
                &ev.op
                && self.config.is_retired(status)
            {
                return Err(Error::Rejected(Rejection {
                    code: RejectCode::RetiredStatus,
                    message: format!(
                        "status {status:?} is retired; choose one of {}",
                        state
                            .statuses
                            .iter()
                            .filter(|s| !self.config.is_retired(s))
                            .map(String::as_str)
                            .collect::<Vec<_>>()
                            .join(", ")
                    ),
                }));
            }
            if let Op::Priority(d) = &ev.op
                && d.to
                    .is_some_and(|value| !self.config.priority.contains(value))
            {
                return Err(Error::Rejected(Rejection {
                    code: RejectCode::InvalidPriority,
                    message: format!(
                        "priority is outside configured range {}..{}",
                        self.config.priority.highest, self.config.priority.lowest
                    ),
                }));
            }
            let mut trial = state.clone();
            let applied = apply(&mut trial, &ev).map_err(Error::Rejected)?;
            if applied.changed
                && let Op::Depend(d) = &ev.op
                && state.dependency_reaches(d.to, entity)
            {
                return Err(Error::Rejected(Rejection {
                    code: RejectCode::DependencyCycle,
                    message: format!("dependency {entity} -> {} would close a cycle", d.to),
                }));
            }
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
            if let Some(i) = index {
                planned.push(id);
                outcomes[i] = Some(id);
            }
            events.push(ev);
        }
        if planned.is_empty() {
            // Nothing but a possible actor declaration: write nothing.
            let w = Written {
                events: Vec::new(),
                identity,
                planned,
                outcomes,
                replay: rp,
                sync: None,
            };
            return Ok((w, Vec::new()));
        }
        if opts.dry_run {
            rp.state = state;
            rp.events.extend(events.iter().cloned());
            rp.highest_seen = highest;
            let w = Written {
                events,
                identity,
                planned,
                outcomes,
                replay: rp,
                sync: None,
            };
            return Ok((w, Vec::new()));
        }
        if identity.is_none() {
            return Err(Error::ActorRequired);
        }
        let files = before_append(&events)?;

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
        let w = Written {
            events,
            identity,
            planned,
            outcomes,
            replay: rp,
            sync: None,
        };
        Ok((w, files))
    }

    /// The identity a write names: `flag`, else the clone's
    /// `zwanenzang.defaultActor`, refused unless the tracker accepts it.
    /// `None` when neither is set.
    fn write_identity(&self, repo: &Repo, flag: Option<&str>) -> Result<Option<String>> {
        let (name, source) = match flag {
            Some(n) => (n.to_string(), "--actor-name"),
            None => match repo.config_get(DEFAULT_ACTOR_KEY)? {
                Some(n) => (n.trim().to_string(), DEFAULT_ACTOR_KEY),
                None => return Ok(None),
            },
        };
        if self.config.accepts_identity(&name) {
            return Ok(Some(name));
        }
        Err(Error::UnknownActor(match &self.config.actors {
            Some(list) => format!(
                "{source} {name:?} is not one of the actors in zwanenzang.toml: {}",
                list.join(", ")
            ),
            None => format!(
                "{source} {name:?} is not a valid actor name: use letters, digits, `_` and `-`"
            ),
        }))
    }
}

/// `<op> <ticket>` for the main event, with a count of the others.
fn commit_message(tracker: &Tracker, w: &Written) -> String {
    let view = crate::view::View::new(tracker, &w.replay);
    let Some(ev) = w.primary() else {
        return format!("{} events", w.events.len());
    };
    let what = match w.replay.state.tickets.get(&ev.entity) {
        Some(t) => view.display(t),
        None => "tracker".to_string(),
    };
    match w.events.len() {
        1 => format!("{} {what}", ev.op.name()),
        n => format!("{} {what} (+{} events)", ev.op.name(), n - 1),
    }
}

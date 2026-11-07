//! Derived state and the one function that validates and applies an event.
//!
//! [`apply`] is used both by replay, where a rejection means the event is
//! skipped and reported, and by live writes, where a rejection is an error
//! and nothing is written. Using one function keeps the two identical.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

use serde::Serialize;
use serde_json::{Value, json};

use crate::config::Config;
use crate::event::{Event, Op};
use crate::names::{valid_actor_name, valid_blob_name, valid_name, valid_tag, valid_title};
use crate::ulid::Ulid;

/// Why an event was refused. The string form is a stable machine code.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum RejectCode {
    /// The line is not a valid event envelope.
    Malformed,
    /// The operation is known but its data does not parse.
    InvalidData,
    /// The operation is not known to this build.
    UnknownOp,
    /// The event's actor is not the log it was found in.
    ActorMismatch,
    /// Different lines share one id.
    DuplicateId,
    /// The event id does not sort after its parent.
    IdNotAfterParent,
    /// The event id's time is more than [`crate::clock::MAX_LEAP_MS`] after
    /// the newest id before it, or after the tracker root for the first.
    IdOutOfRange,
    UnknownEntity,
    EntityExists,
    /// A `create` whose entity is not its own id.
    CreateIdMismatch,
    /// A ticket operation on the tracker root, or a tracker operation on a
    /// ticket.
    WrongEntity,
    Tombstoned,
    InvalidTitle,
    StatusNotInVocabulary,
    KindNotInVocabulary,
    InvalidTag,
    InvalidName,
    UnknownTarget,
    TargetTombstoned,
    ParentCycle,
    SelfRelation,
    /// A document write whose base is not the current version. Only ever a
    /// live-write error; at replay such a version is kept and marked lost.
    StaleDocBase,
    MissingBlob,
    InvalidComment,
    NumberNotUnique,
    NumberNotGreater,
    AlreadyNumbered,
}

impl RejectCode {
    pub fn as_str(self) -> &'static str {
        match self {
            RejectCode::Malformed => "malformed",
            RejectCode::InvalidData => "invalid-data",
            RejectCode::UnknownOp => "unknown-op",
            RejectCode::ActorMismatch => "actor-mismatch",
            RejectCode::DuplicateId => "duplicate-id",
            RejectCode::IdNotAfterParent => "id-not-after-parent",
            RejectCode::IdOutOfRange => "id-out-of-range",
            RejectCode::UnknownEntity => "unknown-entity",
            RejectCode::EntityExists => "entity-exists",
            RejectCode::CreateIdMismatch => "create-id-mismatch",
            RejectCode::WrongEntity => "wrong-entity",
            RejectCode::Tombstoned => "tombstoned",
            RejectCode::InvalidTitle => "invalid-title",
            RejectCode::StatusNotInVocabulary => "status-not-in-vocabulary",
            RejectCode::KindNotInVocabulary => "kind-not-in-vocabulary",
            RejectCode::InvalidTag => "invalid-tag",
            RejectCode::InvalidName => "invalid-name",
            RejectCode::UnknownTarget => "unknown-target",
            RejectCode::TargetTombstoned => "target-tombstoned",
            RejectCode::ParentCycle => "parent-cycle",
            RejectCode::SelfRelation => "self-relation",
            RejectCode::StaleDocBase => "stale-doc-base",
            RejectCode::MissingBlob => "missing-blob",
            RejectCode::InvalidComment => "invalid-comment",
            RejectCode::NumberNotUnique => "number-not-unique",
            RejectCode::NumberNotGreater => "number-not-greater",
            RejectCode::AlreadyNumbered => "already-numbered",
        }
    }
}

impl Serialize for RejectCode {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(self.as_str())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rejection {
    pub code: RejectCode,
    pub message: String,
}

impl fmt::Display for Rejection {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

fn reject<T>(code: RejectCode, message: impl Into<String>) -> Result<T, Rejection> {
    Err(Rejection {
        code,
        message: message.into(),
    })
}

/// Where and by whom an event was written.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct EventRef {
    pub id: Ulid,
    pub actor: Ulid,
    pub ts: String,
}

impl EventRef {
    fn of(ev: &Event) -> EventRef {
        EventRef {
            id: ev.id,
            actor: ev.actor,
            ts: ev.ts.clone(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Comment {
    pub id: Ulid,
    pub actor: Ulid,
    pub ts: String,
    pub text: Option<String>,
    pub blob: Option<String>,
    pub link: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct DocVersion {
    pub id: Ulid,
    pub actor: Ulid,
    pub ts: String,
    pub blob: String,
    pub base: Option<Ulid>,
    /// True when `base` was not the current version at replay; the version
    /// is kept in history but never became current.
    pub lost: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct Document {
    pub current: Option<Ulid>,
    pub versions: Vec<DocVersion>,
}

impl Document {
    pub fn current_version(&self) -> Option<&DocVersion> {
        let id = self.current?;
        self.versions.iter().find(|v| v.id == id)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Ticket {
    pub id: Ulid,
    pub number: Option<u64>,
    pub title: String,
    pub status: String,
    pub kind: Option<String>,
    pub parent: Option<Ulid>,
    pub related: BTreeSet<Ulid>,
    pub tags: BTreeSet<String>,
    pub branches: BTreeSet<(String, String)>,
    pub mrs: BTreeSet<(String, String)>,
    pub archived: bool,
    pub tombstoned: bool,
    pub comments: Vec<Comment>,
    pub documents: BTreeMap<String, Document>,
    pub created: EventRef,
    /// The latest accepted event whose entity is this ticket.
    pub last_event: Ulid,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ActorInfo {
    /// Declared by the actor's latest accepted `actor` event.
    pub name: Option<String>,
    pub events: usize,
}

/// The scalar fields whose concurrent changes lint reports.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Field {
    Title,
    Status,
    Kind,
    Parent,
}

impl Field {
    pub fn as_str(self) -> &'static str {
        match self {
            Field::Title => "title",
            Field::Status => "status",
            Field::Kind => "kind",
            Field::Parent => "parent",
        }
    }
}

/// The causal facts of an event that classify concurrency.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Causal {
    pub id: Ulid,
    pub actor: Ulid,
    pub parent: Option<Ulid>,
}

impl Causal {
    pub fn of(ev: &Event) -> Causal {
        Causal {
            id: ev.id,
            actor: ev.actor,
            parent: ev.parent,
        }
    }
}

/// For `a` before `b` in ULID order: `b` is concurrent with `a` when they
/// come from different actors and `b`'s writer had not seen `a`, that is
/// `b.parent < a.id` (or `b` has no parent). Events of one actor are never
/// concurrent with each other.
pub fn is_concurrent(a: &Causal, b: &Causal) -> bool {
    debug_assert!(a.id < b.id);
    a.actor != b.actor && b.parent.is_none_or(|p| p < a.id)
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct FieldChange {
    causal: Causal,
    value: Value,
}

/// Two concurrent changes to one scalar field of one ticket.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ConcurrentChange {
    pub entity: Ulid,
    pub field: &'static str,
    pub earlier: Ulid,
    pub earlier_value: Value,
    pub later: Ulid,
    pub later_value: Value,
    /// The later event in ULID order, whose value prevailed over the earlier.
    pub won: Ulid,
}

/// A document version whose base was stale at replay.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LostDoc {
    pub entity: Ulid,
    pub name: String,
    pub event: Ulid,
    pub actor: Ulid,
    pub base: Option<Ulid>,
    /// The version that was current when the lost one was replayed.
    pub current: Option<Ulid>,
}

#[derive(Debug, Clone)]
pub struct Applied {
    /// False when the event left derived state as it was (the same status
    /// again, an existing tag). Live writes do not write such events.
    pub changed: bool,
    /// Set when a document version with a stale base was kept as lost.
    pub lost: Option<LostDoc>,
}

#[derive(Debug, Clone)]
pub struct State {
    pub root: Ulid,
    pub statuses: Vec<String>,
    pub kinds: Vec<String>,
    pub tickets: BTreeMap<Ulid, Ticket>,
    pub numbers: BTreeMap<u64, Ulid>,
    pub actors: BTreeMap<Ulid, ActorInfo>,
    /// Blob names known to exist.
    pub blobs: BTreeSet<String>,
    field_history: BTreeMap<(Ulid, Field), Vec<FieldChange>>,
    pub concurrent: Vec<ConcurrentChange>,
    pub lost_docs: Vec<LostDoc>,
}

impl State {
    pub fn new(config: &Config, blobs: BTreeSet<String>) -> State {
        State {
            root: config.id,
            statuses: config.statuses.clone(),
            kinds: config.kinds.clone(),
            tickets: BTreeMap::new(),
            numbers: BTreeMap::new(),
            actors: BTreeMap::new(),
            blobs,
            field_history: BTreeMap::new(),
            concurrent: Vec::new(),
            lost_docs: Vec::new(),
        }
    }

    pub fn ticket(&self, id: Ulid) -> Option<&Ticket> {
        self.tickets.get(&id)
    }

    fn check_status(&self, s: &str) -> Result<(), Rejection> {
        if self.statuses.iter().any(|v| v == s) {
            Ok(())
        } else {
            reject(
                RejectCode::StatusNotInVocabulary,
                format!("status {s:?} is not in the vocabulary"),
            )
        }
    }

    fn check_kind(&self, k: &str) -> Result<(), Rejection> {
        if self.kinds.iter().any(|v| v == k) {
            Ok(())
        } else {
            reject(
                RejectCode::KindNotInVocabulary,
                format!("kind {k:?} is not in the vocabulary"),
            )
        }
    }

    /// A relation or parent target: an existing, live ticket.
    fn check_target(&self, to: Ulid) -> Result<(), Rejection> {
        match self.tickets.get(&to) {
            None => reject(RejectCode::UnknownTarget, format!("no ticket {to}")),
            Some(t) if t.tombstoned => reject(
                RejectCode::TargetTombstoned,
                format!("ticket {to} is tombstoned"),
            ),
            Some(_) => Ok(()),
        }
    }

    fn check_blob(&self, blob: &str) -> Result<(), Rejection> {
        if valid_blob_name(blob) && self.blobs.contains(blob) {
            Ok(())
        } else {
            reject(
                RejectCode::MissingBlob,
                format!("blob {blob:?} does not exist"),
            )
        }
    }

    /// True when making `parent` the parent of `child` closes a cycle.
    fn would_cycle(&self, child: Ulid, parent: Ulid) -> bool {
        let mut cur = Some(parent);
        let mut steps = 0;
        while let Some(c) = cur {
            if c == child {
                return true;
            }
            steps += 1;
            if steps > self.tickets.len() {
                return true;
            }
            cur = self.tickets.get(&c).and_then(|t| t.parent);
        }
        false
    }

    fn note_field(&mut self, ev: &Event, field: Field, value: Value) {
        let me = Causal::of(ev);
        let history = self.field_history.entry((ev.entity, field)).or_default();
        // Walk back over the changes this writer may not have seen.
        for prior in history.iter().rev() {
            if me.parent.is_some_and(|p| p >= prior.causal.id) {
                break;
            }
            if is_concurrent(&prior.causal, &me) && prior.value != value {
                self.concurrent.push(ConcurrentChange {
                    entity: ev.entity,
                    field: field.as_str(),
                    earlier: prior.causal.id,
                    earlier_value: prior.value.clone(),
                    later: me.id,
                    later_value: value.clone(),
                    won: me.id,
                });
            }
        }
        history.push(FieldChange { causal: me, value });
    }
}

fn single_line(s: &str) -> bool {
    !s.trim().is_empty() && !s.contains(['\n', '\r'])
}

/// Validates `ev` against `state` and, when it is accepted, applies it.
/// A rejected event leaves `state` untouched.
pub fn apply(state: &mut State, ev: &Event) -> Result<Applied, Rejection> {
    if let Some(p) = ev.parent
        && ev.id <= p
    {
        return reject(
            RejectCode::IdNotAfterParent,
            format!("event {} does not sort after its parent {p}", ev.id),
        );
    }
    let mut lost = None;
    let changed = if ev.op.is_tracker_op() {
        if ev.entity != state.root {
            return reject(
                RejectCode::WrongEntity,
                format!("{} events must name the tracker root", ev.op.name()),
            );
        }
        apply_tracker_op(state, ev)?
    } else if ev.entity == state.root {
        return reject(
            RejectCode::WrongEntity,
            format!("{} is a ticket operation", ev.op.name()),
        );
    } else if let Op::Create(d) = &ev.op {
        if ev.entity != ev.id {
            return reject(
                RejectCode::CreateIdMismatch,
                "a create event's entity must be its own id",
            );
        }
        if state.tickets.contains_key(&ev.entity) {
            return reject(RejectCode::EntityExists, format!("{} exists", ev.entity));
        }
        if !valid_title(&d.title) {
            return reject(RejectCode::InvalidTitle, "invalid title");
        }
        state.check_status(&d.status)?;
        if let Some(k) = &d.kind {
            state.check_kind(k)?;
        }
        state.tickets.insert(
            ev.entity,
            Ticket {
                id: ev.entity,
                number: None,
                title: d.title.clone(),
                status: d.status.clone(),
                kind: d.kind.clone(),
                parent: None,
                related: BTreeSet::new(),
                tags: BTreeSet::new(),
                branches: BTreeSet::new(),
                mrs: BTreeSet::new(),
                archived: false,
                tombstoned: false,
                comments: Vec::new(),
                documents: BTreeMap::new(),
                created: EventRef::of(ev),
                last_event: ev.id,
            },
        );
        true
    } else {
        match state.tickets.get(&ev.entity) {
            None => {
                return reject(
                    RejectCode::UnknownEntity,
                    format!("no ticket {}", ev.entity),
                );
            }
            Some(t) if t.tombstoned => {
                return reject(
                    RejectCode::Tombstoned,
                    format!("ticket {} is tombstoned", ev.entity),
                );
            }
            Some(_) => {}
        }
        let (changed, l) = apply_ticket_op(state, ev)?;
        lost = l;
        if let Some(t) = state.tickets.get_mut(&ev.entity) {
            t.last_event = ev.id;
        }
        changed
    };
    state.actors.entry(ev.actor).or_default().events += 1;
    Ok(Applied { changed, lost })
}

fn apply_tracker_op(state: &mut State, ev: &Event) -> Result<bool, Rejection> {
    match &ev.op {
        Op::Actor(d) => {
            if !valid_actor_name(&d.name) {
                return reject(RejectCode::InvalidName, "invalid actor name");
            }
            let info = state.actors.entry(ev.actor).or_default();
            let changed = info.name.as_deref() != Some(d.name.as_str());
            info.name = Some(d.name.clone());
            Ok(changed)
        }
        Op::Config(d) => {
            // A config event may carry only fields a newer build knows; it
            // is then a no-op here, not invalid.
            for n in d.add_statuses.iter().chain(&d.add_kinds) {
                if !valid_name(n) {
                    return reject(RejectCode::InvalidName, format!("invalid name {n:?}"));
                }
            }
            let mut changed = false;
            for (list, adds) in [
                (&mut state.statuses, &d.add_statuses),
                (&mut state.kinds, &d.add_kinds),
            ] {
                for n in adds {
                    if !list.contains(n) {
                        list.push(n.clone());
                        changed = true;
                    }
                }
            }
            Ok(changed)
        }
        _ => unreachable!("not a tracker operation"),
    }
}

fn apply_ticket_op(state: &mut State, ev: &Event) -> Result<(bool, Option<LostDoc>), Rejection> {
    let id = ev.entity;
    let t = &state.tickets[&id];
    let changed = match &ev.op {
        Op::Create(_) | Op::Actor(_) | Op::Config(_) => unreachable!("handled by apply"),
        Op::Number(d) => {
            if d.number == 0 {
                return reject(RejectCode::InvalidData, "numbers start at 1");
            }
            if let Some(n) = t.number {
                return reject(
                    RejectCode::AlreadyNumbered,
                    format!("ticket already has number {n}"),
                );
            }
            if state.numbers.contains_key(&d.number) {
                return reject(
                    RejectCode::NumberNotUnique,
                    format!("number {} is taken", d.number),
                );
            }
            if let Some((&max, _)) = state.numbers.last_key_value()
                && d.number < max
            {
                return reject(
                    RejectCode::NumberNotGreater,
                    format!("number {} is below the highest number {max}", d.number),
                );
            }
            state.numbers.insert(d.number, id);
            state.tickets.get_mut(&id).unwrap().number = Some(d.number);
            true
        }
        Op::Title(d) => {
            if !valid_title(&d.to) {
                return reject(RejectCode::InvalidTitle, "invalid title");
            }
            let changed = t.title != d.to;
            state.tickets.get_mut(&id).unwrap().title = d.to.clone();
            state.note_field(ev, Field::Title, json!(d.to));
            changed
        }
        Op::Status(d) => {
            state.check_status(&d.to)?;
            let changed = t.status != d.to;
            state.tickets.get_mut(&id).unwrap().status = d.to.clone();
            state.note_field(ev, Field::Status, json!(d.to));
            changed
        }
        Op::Kind(d) => {
            if let Some(k) = &d.to {
                state.check_kind(k)?;
            }
            let changed = t.kind != d.to;
            state.tickets.get_mut(&id).unwrap().kind = d.to.clone();
            state.note_field(ev, Field::Kind, json!(d.to));
            changed
        }
        Op::Parent(d) => {
            if let Some(p) = d.to {
                if p == id {
                    return reject(RejectCode::ParentCycle, "a ticket cannot be its own parent");
                }
                state.check_target(p)?;
                if state.would_cycle(id, p) {
                    return reject(
                        RejectCode::ParentCycle,
                        format!("{p} is a descendant of {id}"),
                    );
                }
            }
            let changed = t.parent != d.to;
            state.tickets.get_mut(&id).unwrap().parent = d.to;
            state.note_field(ev, Field::Parent, json!(d.to));
            changed
        }
        Op::Relate(d) => {
            if d.to == id {
                return reject(RejectCode::SelfRelation, "a ticket cannot relate to itself");
            }
            state.check_target(d.to)?;
            let changed = state.tickets.get_mut(&id).unwrap().related.insert(d.to);
            state.tickets.get_mut(&d.to).unwrap().related.insert(id);
            changed
        }
        Op::Unrelate(d) => {
            if d.to == id {
                return reject(RejectCode::SelfRelation, "a ticket cannot relate to itself");
            }
            if !state.tickets.contains_key(&d.to) {
                return reject(RejectCode::UnknownTarget, format!("no ticket {}", d.to));
            }
            let changed = state.tickets.get_mut(&id).unwrap().related.remove(&d.to);
            state.tickets.get_mut(&d.to).unwrap().related.remove(&id);
            changed
        }
        Op::Branch(d) => {
            if !valid_name(&d.repo) {
                return reject(
                    RejectCode::InvalidName,
                    format!("invalid repository alias {:?}", d.repo),
                );
            }
            if !single_line(&d.name) {
                return reject(
                    RejectCode::InvalidData,
                    "branch name must be a non-empty single line",
                );
            }
            let entry = (d.repo.clone(), d.name.clone());
            state.tickets.get_mut(&id).unwrap().branches.insert(entry)
        }
        Op::Mr(d) => {
            if !valid_name(&d.repo) {
                return reject(
                    RejectCode::InvalidName,
                    format!("invalid repository alias {:?}", d.repo),
                );
            }
            if !single_line(&d.url) {
                return reject(
                    RejectCode::InvalidData,
                    "merge request url must be a non-empty single line",
                );
            }
            let entry = (d.repo.clone(), d.url.clone());
            state.tickets.get_mut(&id).unwrap().mrs.insert(entry)
        }
        Op::Tag(d) | Op::Untag(d) => {
            if !valid_tag(&d.tag) {
                return reject(RejectCode::InvalidTag, format!("invalid tag {:?}", d.tag));
            }
            let tags = &mut state.tickets.get_mut(&id).unwrap().tags;
            if matches!(ev.op, Op::Tag(_)) {
                tags.insert(d.tag.clone())
            } else {
                tags.remove(&d.tag)
            }
        }
        Op::Archive(_) => {
            let t = state.tickets.get_mut(&id).unwrap();
            let changed = !t.archived;
            t.archived = true;
            changed
        }
        Op::Tombstone(_) => {
            state.tickets.get_mut(&id).unwrap().tombstoned = true;
            true
        }
        Op::Comment(d) => {
            match (&d.text, &d.blob) {
                (Some(text), None) => {
                    if text.trim().is_empty() {
                        return reject(RejectCode::InvalidComment, "comment text is empty");
                    }
                }
                (None, Some(blob)) => state.check_blob(blob)?,
                _ => {
                    return reject(
                        RejectCode::InvalidComment,
                        "a comment has exactly one of text and blob",
                    );
                }
            }
            if let Some(link) = &d.link
                && !single_line(link)
            {
                return reject(
                    RejectCode::InvalidComment,
                    "link must be a non-empty single line",
                );
            }
            state.tickets.get_mut(&id).unwrap().comments.push(Comment {
                id: ev.id,
                actor: ev.actor,
                ts: ev.ts.clone(),
                text: d.text.clone(),
                blob: d.blob.clone(),
                link: d.link.clone(),
            });
            true
        }
        Op::Doc(d) => {
            if !valid_name(&d.name) {
                return reject(
                    RejectCode::InvalidName,
                    format!("invalid document name {:?}", d.name),
                );
            }
            state.check_blob(&d.blob)?;
            let doc = state
                .tickets
                .get_mut(&id)
                .unwrap()
                .documents
                .entry(d.name.clone())
                .or_default();
            let current = doc.current;
            let is_current_base = d.base == current;
            let same_text = doc.current_version().is_some_and(|v| v.blob == d.blob);
            doc.versions.push(DocVersion {
                id: ev.id,
                actor: ev.actor,
                ts: ev.ts.clone(),
                blob: d.blob.clone(),
                base: d.base,
                lost: !is_current_base,
            });
            if is_current_base {
                doc.current = Some(ev.id);
                !same_text
            } else {
                let l = LostDoc {
                    entity: id,
                    name: d.name.clone(),
                    event: ev.id,
                    actor: ev.actor,
                    base: d.base,
                    current,
                };
                state.lost_docs.push(l.clone());
                return Ok((false, Some(l)));
            }
        }
    };
    Ok((changed, None))
}

//! One read of a scope, with event cursors that detect late-arriving history.

use std::collections::{BTreeMap, BTreeSet};

use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::error::{Error, Result};
use crate::event::{Event, Op};
use crate::store::Tracker;
use crate::ulid::Ulid;
use crate::view::View;

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    /// Headings already present, including archived/tombstoned tickets.
    #[serde(default)]
    pub cursors: BTreeMap<String, Option<String>>,
    /// Scope cursor from the previous read; limits discovery of absent tickets.
    pub since: Option<String>,
}

fn invalid(message: impl Into<String>) -> Error {
    Error::InvalidArgument(message.into())
}

/// Hash the canonical event stream, with a tracker/entity domain. Unlike a
/// bare maximum id, this detects events merged later below the cursor.
fn cursor(domain: Ulid, events: &[&Event]) -> Option<String> {
    let last = events.last()?;
    let mut hash = Sha256::new();
    hash.update(domain.to_canonical());
    for e in events {
        hash.update(e.to_line());
        hash.update(b"\n");
    }
    Some(format!("{}:{:x}", last.id, hash.finalize()))
}

/// Return the suffix offset and whether the caller must reconsider history.
fn after(domain: Ulid, events: &[&Event], token: Option<&str>) -> Result<(usize, bool)> {
    let Some(token) = token else {
        return Ok((0, false));
    };
    let (id, hash) = token
        .split_once(':')
        .ok_or_else(|| invalid("invalid read cursor"))?;
    let id = Ulid::parse_canonical(id).map_err(|_| invalid("invalid read cursor"))?;
    if hash.len() != 64
        || !hash
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return Err(invalid("invalid read cursor"));
    }
    let n = events.partition_point(|e| e.id <= id);
    if cursor(domain, &events[..n]).as_deref() == Some(token) {
        Ok((n, false))
    } else {
        Ok((0, true))
    }
}

/// Index accepted events by every ticket whose visible state they affect.
/// Keep the old parent while walking history: final state alone cannot tell
/// which parent lost a child. Relations are indexed on both ends, even when
/// the other end is tombstoned later.
fn affected(events: &[Event]) -> BTreeMap<Ulid, Vec<&Event>> {
    let mut out: BTreeMap<Ulid, Vec<&Event>> = BTreeMap::new();
    let mut parents: BTreeMap<Ulid, Ulid> = BTreeMap::new();
    let mut relations: BTreeMap<Ulid, BTreeSet<Ulid>> = BTreeMap::new();
    for e in events {
        if e.op.is_tracker_op() {
            continue;
        }
        let mut ids = BTreeSet::from([e.entity]);
        match &e.op {
            Op::Parent(d) => {
                if let Some(old) = parents.remove(&e.entity) {
                    ids.insert(old);
                }
                if let Some(new) = d.to {
                    ids.insert(new);
                    parents.insert(e.entity, new);
                }
            }
            Op::Relate(d) => {
                ids.insert(d.to);
                relations.entry(e.entity).or_default().insert(d.to);
                relations.entry(d.to).or_default().insert(e.entity);
            }
            Op::Unrelate(d) => {
                ids.insert(d.to);
                relations.entry(e.entity).or_default().remove(&d.to);
                relations.entry(d.to).or_default().remove(&e.entity);
            }
            Op::Depend(d) | Op::Undepend(d) => {
                // Both forward and reverse views retain tombstoned endpoints.
                ids.insert(d.to);
            }
            Op::Tombstone(_) => {
                ids.extend(parents.get(&e.entity).copied());
                ids.extend(relations.get(&e.entity).into_iter().flatten().copied());
            }
            _ => {}
        }
        for id in ids {
            out.entry(id).or_default().push(e);
        }
    }
    out
}

pub fn read(tracker: &Tracker, request: Request) -> Result<Value> {
    let rp = tracker.load()?;
    let view = View::new(tracker, &rp);
    let all: Vec<_> = rp.events.iter().collect();
    let (scope_offset, reset) = after(tracker.config.id, &all, request.since.as_deref())?;
    let new_ids: BTreeSet<_> = all[scope_offset..].iter().map(|e| e.id).collect();
    let mut known = BTreeMap::new();
    for (reference, token) in request.cursors {
        let id = view.resolve(&reference)?;
        if known.insert(id, token).is_some() {
            return Err(invalid("two read cursors refer to the same ticket"));
        }
    }
    let index = affected(&rp.events);
    let mut tickets = Vec::new();
    for t in rp.state.tickets.values() {
        let events = index.get(&t.id).map(Vec::as_slice).unwrap_or_default();
        let present = known.contains_key(&t.id);
        if !present
            && (t.archived || t.tombstoned || !events.iter().any(|e| new_ids.contains(&e.id)))
        {
            continue;
        }
        let token = known.get(&t.id).and_then(|c| c.as_deref());
        let (offset, ticket_reset) = after(t.id, events, token)?;
        let mut documents = BTreeMap::new();
        for (name, doc) in &t.documents {
            if let Some(v) = doc.current_version() {
                documents.insert(name, tracker.get_blob(&v.blob)?);
            }
        }
        tickets.push(json!({
            "ticket": view.ticket(t),
            "documents": documents,
            "events": events[offset..],
            "cursor": cursor(t.id, events),
            "reset": ticket_reset,
        }));
    }
    let actors: BTreeMap<String, &String> = rp
        .state
        .actors
        .iter()
        .filter_map(|(id, info)| info.name.as_ref().map(|n| (id.to_string(), n)))
        .collect();
    Ok(json!({
        "tracker": {
            "id": tracker.config.id,
            "name": tracker.config.name,
            "prefix": tracker.config.prefix,
            "statuses": rp.state.statuses,
            "kinds": rp.state.kinds,
            "priority": tracker.config.priority,
            "actors": actors,
        },
        "cursor": cursor(tracker.config.id, &all),
        "reset": reset,
        "tickets": tickets,
    }))
}

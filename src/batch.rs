//! Client batches compiled to one ordinary live-write plan.

use std::collections::{BTreeMap, BTreeSet};

use serde::Deserialize;
use serde_json::{Value, json};

use crate::cli::INLINE_COMMENT_LIMIT;
use crate::clock::Clock;
use crate::error::{Error, Result};
use crate::event::{Op, OpError};
use crate::state::{RejectCode, Rejection};
use crate::store::{Tracker, blob_name};
use crate::ulid::Ulid;
use crate::view::View;
use crate::workflow::DEFAULT_STATUS;
use crate::write::{Plan, Target, WriteOptions};

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    pub changes: Vec<Change>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Change {
    pub op: String,
    pub ticket: Option<Reference>,
    pub data: Value,
}

#[derive(Debug, Deserialize)]
#[serde(untagged)]
pub enum Reference {
    Existing(String),
    Created(Created),
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Created {
    pub created: usize,
}

fn invalid(message: impl Into<String>) -> Error {
    Error::InvalidArgument(message.into())
}

fn target(reference: Reference, view: &View, created: &BTreeMap<usize, usize>) -> Result<Target> {
    match reference {
        Reference::Existing(s) => Ok(Target::Entity(view.resolve(&s)?)),
        Reference::Created(c) => created
            .get(&c.created)
            .copied()
            .map(Target::Nth)
            .ok_or_else(|| invalid("created reference must name an earlier create change")),
    }
}

/// Validate the entire batch under the normal write lock, then commit and
/// sync once. Results retain input order even when operations are no-ops.
pub fn apply(
    tracker: &Tracker,
    clock: &mut dyn Clock,
    actor_name: Option<&str>,
    request: Request,
) -> Result<Value> {
    let mut targets = Vec::new();
    let mut creations = BTreeMap::new();
    // Relative planning dates resolve against the local date when the
    // batch runs, as on the command line.
    let today = crate::clock::local_today(clock);
    let w = tracker.write_with(
        clock,
        WriteOptions {
            actor_name,
            message: Some("apply client batch"),
            ..WriteOptions::default()
        },
        |rp| {
            let view = View::new(tracker, rp);
            let mut plan = Plan::default();
            for (i, change) in request.changes.into_iter().enumerate() {
                let mut data = change.data;
                let fields: &[&str] = match change.op.as_str() {
                    "create" => &["title", "status", "kind"],
                    "title" | "status" | "kind" | "priority" | "scheduled" | "parent"
                    | "relate" | "unrelate" | "depend" | "undepend" => &["to"],
                    "tag" | "untag" => &["tag"],
                    "branch" => &["repo", "name"],
                    "mr" => &["repo", "url"],
                    "archive" | "unarchive" | "tombstone" => &[],
                    "doc" => &["name", "text", "base"],
                    "comment" => &["text", "link"],
                    _ => {
                        return Err(invalid(format!(
                            "unsupported batch operation {:?}",
                            change.op
                        )));
                    }
                };
                let object = data
                    .as_object_mut()
                    .ok_or_else(|| invalid("change data must be an object"))?;
                if object.keys().any(|k| !fields.contains(&k.as_str())) {
                    return Err(invalid(format!("unknown data field in change {i}")));
                }
                let entity = if change.op == "create" {
                    if change.ticket.is_some() {
                        return Err(invalid("create must omit ticket"));
                    }
                    object
                        .entry("status")
                        .or_insert_with(|| json!(DEFAULT_STATUS));
                    let n = creations.len();
                    creations.insert(i, n);
                    Target::Nth(n)
                } else {
                    target(
                        change
                            .ticket
                            .ok_or_else(|| invalid("change requires ticket"))?,
                        &view,
                        &creations,
                    )?
                };
                if matches!(
                    change.op.as_str(),
                    "parent" | "relate" | "unrelate" | "depend" | "undepend"
                ) {
                    let to = object
                        .get("to")
                        .ok_or_else(|| invalid("missing field `to`"))?;
                    if !to.is_null() || change.op != "parent" {
                        let reference = serde_json::from_value(to.clone())
                            .map_err(|e| invalid(format!("invalid target: {e}")))?;
                        let to = target(reference, &view, &creations)?;
                        plan.refs.push((i, to));
                        // The write core substitutes the actual id, including
                        // ids of earlier creations, before applying the event.
                        object.insert("to".into(), json!(tracker.config.id));
                    }
                }
                if change.op == "scheduled"
                    && let Some(Value::String(input)) = object.get("to")
                {
                    let value =
                        crate::planning::resolve_input(input, today).map_err(Error::Rejected)?;
                    object.insert("to".into(), json!(value));
                }
                if matches!(change.op.as_str(), "doc" | "comment") {
                    let text = object
                        .remove("text")
                        .and_then(|v| v.as_str().map(str::to_owned))
                        .ok_or_else(|| invalid("text must be a string"))?;
                    if change.op == "comment" && text.trim().is_empty() {
                        return Err(Error::Rejected(Rejection {
                            code: RejectCode::InvalidComment,
                            message: "comment text is empty".into(),
                        }));
                    }
                    if change.op == "doc" || text.len() > INLINE_COMMENT_LIMIT {
                        object.insert("blob".into(), json!(blob_name(&text)));
                        plan.blobs.push(text);
                    } else {
                        object.insert("text".into(), json!(text));
                    }
                }
                let op = Op::from_parts(&change.op, data).map_err(|e| match e {
                    OpError::Invalid(m) | OpError::Unknown(m) => invalid(m),
                })?;
                targets.push(entity);
                plan.ops.push((entity, op));
            }
            Ok(plan)
        },
        |_| Ok(Vec::new()),
    )?;
    let created_ids: Vec<Ulid> = w
        .events
        .iter()
        .filter(|e| matches!(e.op, Op::Create(_)))
        .map(|e| e.entity)
        .collect();
    let resolve = |t| match t {
        Target::Entity(id) => id,
        Target::Nth(n) => created_ids[n],
        Target::Created => unreachable!("batch uses indexed targets"),
    };
    let view = View::new(tracker, &w.replay);
    let results: Vec<_> = targets
        .iter()
        .zip(&w.outcomes)
        .map(|(&t, event)| {
            json!({
                "ticket": resolve(t), "written": event.is_some(), "event": event,
            })
        })
        .collect();
    let ids: BTreeSet<_> = targets.into_iter().map(resolve).collect();
    let tickets: Vec<_> = ids
        .iter()
        .map(|id| view.ticket(&w.replay.state.tickets[id]))
        .collect();
    let created: BTreeMap<_, _> = creations
        .into_iter()
        .map(|(i, n)| (i, created_ids[n]))
        .collect();
    Ok(
        json!({"written": w.written(), "results": results, "created": created,
        "tickets": tickets, "events": w.events, "sync": w.sync}),
    )
}

//! Replay: every log line of a tracker, in ULID order, through [`apply`].
//! Replay is total; whatever fails is skipped and reported.

use std::collections::{BTreeMap, BTreeSet};

use serde::Serialize;
use serde_json::Value;

use crate::clock::leaps_too_far;
use crate::config::Config;
use crate::event::{Event, OpError, RawEnvelope};
use crate::state::{RejectCode, State, apply};
use crate::store::LogLine;
use crate::ulid::Ulid;

/// A log line that replay did not apply.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Skipped {
    /// The log file stem (normally the actor id).
    pub log: String,
    pub line: usize,
    pub id: Option<Ulid>,
    pub op: Option<String>,
    pub code: RejectCode,
    pub message: String,
    /// The line exactly as found; for a line that is not valid UTF-8, a
    /// lossy rendering of it.
    pub raw: String,
}

#[derive(Debug, Clone)]
pub struct Replay {
    pub state: State,
    /// Accepted events in ULID order.
    pub events: Vec<Event>,
    pub skipped: Vec<Skipped>,
    /// The highest id of any parseable envelope, accepted or not, that is
    /// not out of range. New ids must sort after it, and it is the parent
    /// of the next event.
    pub highest_seen: Option<Ulid>,
}

fn skipped(
    line: &LogLine,
    id: Option<Ulid>,
    op: Option<String>,
    code: RejectCode,
    message: String,
) -> Skipped {
    Skipped {
        log: line.log.clone(),
        line: line.line_no,
        id,
        op,
        code,
        message,
        raw: line.text.clone(),
    }
}

/// Best-effort id and op of a line that is not a valid envelope, for the
/// report only.
fn salvage(text: &str) -> (Option<Ulid>, Option<String>) {
    let Ok(v) = serde_json::from_str::<Value>(text) else {
        return (None, None);
    };
    let id = v
        .get("id")
        .and_then(Value::as_str)
        .and_then(|s| Ulid::parse_canonical(s).ok());
    let op = v.get("op").and_then(Value::as_str).map(str::to_string);
    (id, op)
}

pub fn replay(config: &Config, blobs: BTreeSet<String>, lines: &[LogLine]) -> Replay {
    let mut skipped_lines = Vec::new();
    let mut by_id: BTreeMap<Ulid, Vec<(&LogLine, RawEnvelope)>> = BTreeMap::new();
    for line in lines {
        if !line.utf8 {
            skipped_lines.push(skipped(
                line,
                None,
                None,
                RejectCode::Malformed,
                "line is not valid UTF-8".into(),
            ));
            continue;
        }
        match RawEnvelope::parse(&line.text) {
            Ok(env) => by_id.entry(env.id).or_default().push((line, env)),
            Err(e) => {
                let (id, op) = salvage(&line.text);
                skipped_lines.push(skipped(line, id, op, RejectCode::Malformed, e));
            }
        }
    }
    let mut state = State::new(config, blobs);
    let mut events = Vec::new();
    // The newest id seen so far, starting from the tracker root; an id too
    // far after it is out of range and is not seen.
    let mut anchor = config.id;
    let mut highest_seen = None;
    for (id, occurrences) in by_id {
        if leaps_too_far(anchor, id) {
            for (line, env) in &occurrences {
                skipped_lines.push(skipped(
                    line,
                    Some(id),
                    Some(env.op.clone()),
                    RejectCode::IdOutOfRange,
                    format!(
                        "id {id} is more than 1000 years after {anchor}, the newest id before it"
                    ),
                ));
            }
            continue;
        }
        anchor = anchor.max(id);
        highest_seen = Some(id);
        let distinct: BTreeSet<&str> = occurrences.iter().map(|(l, _)| l.text.as_str()).collect();
        if distinct.len() > 1 {
            for (line, env) in &occurrences {
                skipped_lines.push(skipped(
                    line,
                    Some(id),
                    Some(env.op.clone()),
                    RejectCode::DuplicateId,
                    format!("{} different lines share id {id}", distinct.len()),
                ));
            }
            continue;
        }
        // Byte-identical lines count once; a copy in another actor's log is
        // misplaced and reported.
        let mut own = None;
        for (line, env) in occurrences {
            if line.log == env.actor.to_canonical() {
                if own.is_none() {
                    own = Some((line, env));
                }
            } else {
                skipped_lines.push(skipped(
                    line,
                    Some(id),
                    Some(env.op.clone()),
                    RejectCode::ActorMismatch,
                    format!("event by actor {} found in log {}", env.actor, line.log),
                ));
            }
        }
        let Some((line, env)) = own else { continue };
        let op_name = env.op.clone();
        let ev = match Event::from_raw(env) {
            Ok(ev) => ev,
            Err(OpError::Unknown(op)) => {
                skipped_lines.push(skipped(
                    line,
                    Some(id),
                    Some(op_name),
                    RejectCode::UnknownOp,
                    format!("operation {op:?} is not known to this build"),
                ));
                continue;
            }
            Err(OpError::Invalid(msg)) => {
                skipped_lines.push(skipped(
                    line,
                    Some(id),
                    Some(op_name),
                    RejectCode::InvalidData,
                    msg,
                ));
                continue;
            }
        };
        match apply(&mut state, &ev) {
            Ok(_) => events.push(ev),
            Err(r) => skipped_lines.push(skipped(line, Some(id), Some(op_name), r.code, r.message)),
        }
    }
    skipped_lines.sort_by(|a, b| (a.id, &a.log, a.line).cmp(&(b.id, &b.log, b.line)));
    Replay {
        state,
        events,
        skipped: skipped_lines,
        highest_seen,
    }
}

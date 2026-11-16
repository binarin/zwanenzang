//! JSON views of derived state, ticket references and display names.

use std::collections::BTreeMap;

use serde_json::{Value, json};

use crate::error::{Error, Result};
use crate::replay::Replay;
use crate::state::{Document, EventRef, Ticket};
use crate::store::Tracker;
use crate::ulid::{Ulid, is_prefix_text};

/// The shortest unique prefix of each entity id, at least 10 characters
/// (the timestamp part).
pub fn short_ids(ids: impl IntoIterator<Item = Ulid>) -> BTreeMap<Ulid, String> {
    let mut sorted: Vec<String> = ids.into_iter().map(Ulid::to_canonical).collect();
    sorted.sort();
    sorted.dedup();
    let lcp = |a: &str, b: &str| a.bytes().zip(b.bytes()).take_while(|(x, y)| x == y).count();
    let mut out = BTreeMap::new();
    for i in 0..sorted.len() {
        let mut need = 10;
        if i > 0 {
            need = need.max(lcp(&sorted[i - 1], &sorted[i]) + 1);
        }
        if i + 1 < sorted.len() {
            need = need.max(lcp(&sorted[i], &sorted[i + 1]) + 1);
        }
        let id = Ulid::parse_canonical(&sorted[i]).expect("canonical");
        out.insert(id, sorted[i][..need.min(26)].to_string());
    }
    out
}

pub struct View<'a> {
    pub tracker: &'a Tracker,
    pub replay: &'a Replay,
    short: BTreeMap<Ulid, String>,
}

impl<'a> View<'a> {
    pub fn new(tracker: &'a Tracker, replay: &'a Replay) -> View<'a> {
        let ids = replay
            .state
            .tickets
            .keys()
            .copied()
            .chain([replay.state.root]);
        View {
            tracker,
            replay,
            short: short_ids(ids),
        }
    }

    pub fn short_id(&self, id: Ulid) -> String {
        self.short
            .get(&id)
            .cloned()
            .unwrap_or_else(|| id.to_canonical())
    }

    pub fn number_text(&self, n: u64) -> String {
        self.tracker.config.number_text(n)
    }

    /// The number when published, the short id otherwise.
    pub fn display(&self, t: &Ticket) -> String {
        match t.number {
            Some(n) => self.number_text(n),
            None => self.short_id(t.id),
        }
    }

    /// Resolves a full ULID, a unique prefix of at least 4 characters
    /// (case-insensitive) or a number such as `ZZ-42`; leading zeros in
    /// the number are accepted, so `zz-0042` is the same ticket.
    pub fn resolve(&self, reference: &str) -> Result<Ulid> {
        let tickets = &self.replay.state.tickets;
        let r = reference.trim();
        let prefix = &self.tracker.config.prefix;
        if let Some((p, digits)) = r.rsplit_once('-')
            && p.eq_ignore_ascii_case(prefix)
            && !digits.is_empty()
            && digits.bytes().all(|b| b.is_ascii_digit())
        {
            let n: u64 = digits
                .parse()
                .map_err(|_| Error::UnknownTicket(reference.into()))?;
            return self
                .replay
                .state
                .numbers
                .get(&n)
                .copied()
                .ok_or_else(|| Error::UnknownTicket(reference.into()));
        }
        if r.len() < 4 || !is_prefix_text(r) {
            return Err(Error::UnknownTicket(reference.into()));
        }
        let up = r.to_ascii_uppercase();
        let matches: Vec<Ulid> = tickets
            .keys()
            .filter(|id| id.to_canonical().starts_with(&up))
            .copied()
            .collect();
        match matches.as_slice() {
            [] => Err(Error::UnknownTicket(reference.into())),
            [one] => Ok(*one),
            many => Err(Error::AmbiguousTicket(
                reference.into(),
                many.iter()
                    .map(|i| i.to_canonical())
                    .collect::<Vec<_>>()
                    .join(", "),
            )),
        }
    }

    /// The identity of an event by writer `actor` with `as` value
    /// `identity`; see [`crate::state::State::identity_of`].
    pub fn identity(&self, actor: Ulid, identity: Option<&str>) -> Option<String> {
        self.replay.state.identity_of(actor, identity)
    }

    /// An event reference with its resolved identity next to the writer.
    pub fn event_ref(&self, r: &EventRef) -> Value {
        json!({
            "id": r.id,
            "actor": r.actor,
            "identity": self.identity(r.actor, r.identity.as_deref()),
            "ts": r.ts,
        })
    }

    fn live(&self, id: &Ulid) -> bool {
        self.replay
            .state
            .tickets
            .get(id)
            .is_some_and(|t| !t.tombstoned)
    }

    pub fn summary(&self, t: &Ticket) -> Value {
        json!({
            "id": t.id,
            "short_id": self.short_id(t.id),
            "number": t.number,
            "display": self.display(t),
            "title": t.title,
            "status": t.status,
            "kind": t.kind,
            "priority": t.priority,
            "parent": t.parent,
            "tags": t.tags,
            "depends_on": t.depends_on,
            "blocks": self.replay.state.tickets.values()
                .filter(|other| other.depends_on.contains(&t.id))
                .map(|other| other.id).collect::<Vec<_>>(),
            "archived": t.archived,
            "tombstoned": t.tombstoned,
            "last_event": t.last_event,
            "activity": self.event_ref(&t.activity),
            "tag_since": t.tag_since.iter()
                .map(|(tag, r)| (tag.clone(), self.event_ref(r)))
                .collect::<BTreeMap<String, Value>>(),
        })
    }

    fn document(&self, d: &Document) -> Value {
        json!({
            "current": d.current,
            "blob": d.current_version().map(|v| &v.blob),
            "versions": d.versions.iter().map(|v| json!({
                "id": v.id,
                "actor": v.actor,
                "identity": self.identity(v.actor, v.identity.as_deref()),
                "ts": v.ts,
                "blob": v.blob,
                "base": v.base,
                "lost": v.lost,
            })).collect::<Vec<_>>(),
        })
    }

    pub fn ticket(&self, t: &Ticket) -> Value {
        let mut children: Vec<Ulid> = self
            .replay
            .state
            .tickets
            .values()
            .filter(|c| c.parent == Some(t.id) && !c.tombstoned)
            .map(|c| c.id)
            .collect();
        children.sort();
        let related: Vec<&Ulid> = t.related.iter().filter(|r| self.live(r)).collect();
        let branches: Vec<Value> = t
            .branches
            .iter()
            .map(|(repo, name)| json!({"repo": repo, "name": name}))
            .collect();
        let mrs: Vec<Value> = t
            .mrs
            .iter()
            .map(|(repo, url)| json!({"repo": repo, "url": url}))
            .collect();
        let documents: BTreeMap<&String, Value> = t
            .documents
            .iter()
            .map(|(n, d)| (n, self.document(d)))
            .collect();
        let comments: Vec<Value> = t
            .comments
            .iter()
            .map(|c| {
                let text = match (&c.text, &c.blob) {
                    (Some(text), _) => Some(text.clone()),
                    (None, Some(b)) => self.tracker.get_blob(b).ok(),
                    (None, None) => None,
                };
                json!({
                    "id": c.id,
                    "actor": c.actor,
                    "identity": self.identity(c.actor, c.identity.as_deref()),
                    "ts": c.ts,
                    "text": text,
                    "blob": c.blob,
                    "link": c.link,
                })
            })
            .collect();
        let mut v = self.summary(t);
        let obj = v.as_object_mut().expect("summary is an object");
        obj.insert("children".into(), json!(children));
        obj.insert("related".into(), json!(related));
        obj.insert("branches".into(), json!(branches));
        obj.insert("mrs".into(), json!(mrs));
        obj.insert("created".into(), self.event_ref(&t.created));
        obj.insert("documents".into(), json!(documents));
        obj.insert("comments".into(), json!(comments));
        v
    }
}

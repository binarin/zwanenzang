//! The event envelope and the typed operations.
//!
//! A line is parsed in two steps: first the envelope, with `op` as a string
//! and `data` as raw JSON, then the data for that operation. An operation from
//! a newer build therefore fails only the second step, and replay can skip it
//! while keeping the line. Unknown fields inside `data` are ignored, because
//! the format grows by adding optional fields.

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize, Serializer};
use serde_json::Value;

use crate::ulid::Ulid;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CreateData {
    pub title: String,
    pub status: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NumberData {
    pub number: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TextTo {
    pub to: String,
}

/// `kind` data; `to: null` clears the kind.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct KindData {
    pub to: Option<String>,
}

/// Native Org priority value; `to: null` removes the explicit priority.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PriorityData {
    pub to: Option<u8>,
}

/// `parent` data; `to: null` clears the parent.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ParentData {
    pub to: Option<Ulid>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RelateData {
    pub to: Ulid,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BranchData {
    pub repo: String,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MrData {
    pub repo: String,
    pub url: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TagData {
    pub tag: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Empty {}

/// `comment` data: exactly one of `text` and `blob`, optional `link`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CommentData {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub blob: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub link: Option<String>,
}

/// `doc` data. `base` is required and may be null for a first version.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DocData {
    pub name: String,
    pub blob: String,
    pub base: Option<Ulid>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ActorData {
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct ConfigData {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub add_statuses: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub add_kinds: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Op {
    Create(CreateData),
    Number(NumberData),
    Title(TextTo),
    Status(TextTo),
    Kind(KindData),
    Priority(PriorityData),
    Parent(ParentData),
    Relate(RelateData),
    Unrelate(RelateData),
    Depend(RelateData),
    Undepend(RelateData),
    Branch(BranchData),
    Mr(MrData),
    Tag(TagData),
    Untag(TagData),
    Archive(Empty),
    Unarchive(Empty),
    Tombstone(Empty),
    Comment(CommentData),
    Doc(DocData),
    Actor(ActorData),
    Config(ConfigData),
}

/// Every operation name this build understands.
pub const OP_NAMES: &[&str] = &[
    "create",
    "number",
    "title",
    "status",
    "kind",
    "priority",
    "parent",
    "relate",
    "unrelate",
    "depend",
    "undepend",
    "branch",
    "mr",
    "tag",
    "untag",
    "archive",
    "unarchive",
    "tombstone",
    "comment",
    "doc",
    "actor",
    "config",
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OpError {
    Unknown(String),
    Invalid(String),
}

impl Op {
    pub fn name(&self) -> &'static str {
        match self {
            Op::Create(_) => "create",
            Op::Number(_) => "number",
            Op::Title(_) => "title",
            Op::Status(_) => "status",
            Op::Kind(_) => "kind",
            Op::Priority(_) => "priority",
            Op::Parent(_) => "parent",
            Op::Relate(_) => "relate",
            Op::Unrelate(_) => "unrelate",
            Op::Depend(_) => "depend",
            Op::Undepend(_) => "undepend",
            Op::Branch(_) => "branch",
            Op::Mr(_) => "mr",
            Op::Tag(_) => "tag",
            Op::Untag(_) => "untag",
            Op::Archive(_) => "archive",
            Op::Unarchive(_) => "unarchive",
            Op::Tombstone(_) => "tombstone",
            Op::Comment(_) => "comment",
            Op::Doc(_) => "doc",
            Op::Actor(_) => "actor",
            Op::Config(_) => "config",
        }
    }

    /// True for operations whose entity is the tracker root.
    pub fn is_tracker_op(&self) -> bool {
        matches!(self, Op::Actor(_) | Op::Config(_))
    }

    pub fn from_parts(op: &str, data: Value) -> Result<Op, OpError> {
        fn p<T: DeserializeOwned>(data: Value) -> Result<T, OpError> {
            if !data.is_object() {
                return Err(OpError::Invalid("data is not an object".into()));
            }
            serde_json::from_value(data).map_err(|e| OpError::Invalid(e.to_string()))
        }
        // Nullable fields that must still be present: a writer has to say
        // which version or parent it means, even when that is none.
        fn require(data: &Value, field: &str) -> Result<(), OpError> {
            match data.get(field) {
                Some(_) => Ok(()),
                None => Err(OpError::Invalid(format!("missing field `{field}`"))),
            }
        }
        Ok(match op {
            "create" => Op::Create(p(data)?),
            "number" => Op::Number(p(data)?),
            "title" => Op::Title(p(data)?),
            "status" => Op::Status(p(data)?),
            "kind" => {
                require(&data, "to")?;
                Op::Kind(p(data)?)
            }
            "priority" => {
                require(&data, "to")?;
                Op::Priority(p(data)?)
            }
            "parent" => {
                require(&data, "to")?;
                Op::Parent(p(data)?)
            }
            "relate" => Op::Relate(p(data)?),
            "unrelate" => Op::Unrelate(p(data)?),
            "depend" => Op::Depend(p(data)?),
            "undepend" => Op::Undepend(p(data)?),
            "branch" => Op::Branch(p(data)?),
            "mr" => Op::Mr(p(data)?),
            "tag" => Op::Tag(p(data)?),
            "untag" => Op::Untag(p(data)?),
            "archive" => Op::Archive(p(data)?),
            "unarchive" => Op::Unarchive(p(data)?),
            "tombstone" => Op::Tombstone(p(data)?),
            "comment" => Op::Comment(p(data)?),
            "doc" => {
                require(&data, "base")?;
                Op::Doc(p(data)?)
            }
            "actor" => Op::Actor(p(data)?),
            "config" => Op::Config(p(data)?),
            other => return Err(OpError::Unknown(other.to_string())),
        })
    }
}

/// Serializes the operation's data object.
impl Serialize for Op {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        match self {
            Op::Create(d) => d.serialize(s),
            Op::Number(d) => d.serialize(s),
            Op::Title(d) | Op::Status(d) => d.serialize(s),
            Op::Kind(d) => d.serialize(s),
            Op::Priority(d) => d.serialize(s),
            Op::Parent(d) => d.serialize(s),
            Op::Relate(d) | Op::Unrelate(d) | Op::Depend(d) | Op::Undepend(d) => d.serialize(s),
            Op::Branch(d) => d.serialize(s),
            Op::Mr(d) => d.serialize(s),
            Op::Tag(d) | Op::Untag(d) => d.serialize(s),
            Op::Archive(d) | Op::Unarchive(d) | Op::Tombstone(d) => d.serialize(s),
            Op::Comment(d) => d.serialize(s),
            Op::Doc(d) => d.serialize(s),
            Op::Actor(d) => d.serialize(s),
            Op::Config(d) => d.serialize(s),
        }
    }
}

/// The envelope as read from a line, before the operation is interpreted.
/// Unknown envelope fields are ignored.
#[derive(Debug, Clone, Deserialize)]
pub struct RawEnvelope {
    pub id: Ulid,
    pub actor: Ulid,
    #[serde(default)]
    pub parent: Option<Ulid>,
    pub ts: String,
    pub entity: Ulid,
    pub op: String,
    pub data: Value,
}

impl RawEnvelope {
    pub fn parse(line: &str) -> Result<RawEnvelope, String> {
        serde_json::from_str(line).map_err(|e| e.to_string())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Event {
    pub id: Ulid,
    pub actor: Ulid,
    pub parent: Option<Ulid>,
    pub ts: String,
    pub entity: Ulid,
    pub op: Op,
}

#[derive(Serialize)]
struct EnvelopeOut<'a> {
    id: Ulid,
    actor: Ulid,
    parent: Option<Ulid>,
    ts: &'a str,
    entity: Ulid,
    op: &'static str,
    data: &'a Op,
}

impl Serialize for Event {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        EnvelopeOut {
            id: self.id,
            actor: self.actor,
            parent: self.parent,
            ts: &self.ts,
            entity: self.entity,
            op: self.op.name(),
            data: &self.op,
        }
        .serialize(s)
    }
}

impl Event {
    pub fn from_raw(raw: RawEnvelope) -> Result<Event, OpError> {
        let op = Op::from_parts(&raw.op, raw.data)?;
        Ok(Event {
            id: raw.id,
            actor: raw.actor,
            parent: raw.parent,
            ts: raw.ts,
            entity: raw.entity,
            op,
        })
    }

    /// The log line for this event, without the trailing newline.
    pub fn to_line(&self) -> String {
        serde_json::to_string(self).expect("events always serialize")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ev(op: Op) -> Event {
        Event {
            id: Ulid::from_parts(10, 1),
            actor: Ulid::from_parts(1, 1),
            parent: Some(Ulid::from_parts(9, 1)),
            ts: "2026-11-07T12:34:56Z".into(),
            entity: Ulid::from_parts(5, 1),
            op,
        }
    }

    #[test]
    fn envelope_field_order() {
        let line = ev(Op::Status(TextTo { to: "doing".into() })).to_line();
        assert_eq!(
            line,
            format!(
                r#"{{"id":"{}","actor":"{}","parent":"{}","ts":"2026-11-07T12:34:56Z","entity":"{}","op":"status","data":{{"to":"doing"}}}}"#,
                Ulid::from_parts(10, 1),
                Ulid::from_parts(1, 1),
                Ulid::from_parts(9, 1),
                Ulid::from_parts(5, 1)
            )
        );
    }

    #[test]
    fn every_op_roundtrips() {
        let u = Ulid::from_parts(7, 7);
        let ops = vec![
            Op::Create(CreateData {
                title: "t".into(),
                status: "draft".into(),
                kind: Some("bug".into()),
            }),
            Op::Number(NumberData { number: 3 }),
            Op::Title(TextTo { to: "x".into() }),
            Op::Status(TextTo { to: "x".into() }),
            Op::Kind(KindData { to: None }),
            Op::Priority(PriorityData { to: Some(10) }),
            Op::Priority(PriorityData { to: None }),
            Op::Parent(ParentData { to: Some(u) }),
            Op::Parent(ParentData { to: None }),
            Op::Relate(RelateData { to: u }),
            Op::Unrelate(RelateData { to: u }),
            Op::Depend(RelateData { to: u }),
            Op::Undepend(RelateData { to: u }),
            Op::Branch(BranchData {
                repo: "app".into(),
                name: "main".into(),
            }),
            Op::Mr(MrData {
                repo: "app".into(),
                url: "https://x/1".into(),
            }),
            Op::Tag(TagData { tag: "a".into() }),
            Op::Untag(TagData { tag: "a".into() }),
            Op::Archive(Empty {}),
            Op::Unarchive(Empty {}),
            Op::Tombstone(Empty {}),
            Op::Comment(CommentData {
                text: Some("hi".into()),
                blob: None,
                link: Some("docs/x.md".into()),
            }),
            Op::Doc(DocData {
                name: "description".into(),
                blob: "ab".into(),
                base: None,
            }),
            Op::Actor(ActorData { name: "me".into() }),
            Op::Config(ConfigData {
                add_statuses: vec!["x".into()],
                add_kinds: vec![],
            }),
        ];
        let mut names: Vec<&str> = ops.iter().map(|o| o.name()).collect();
        names.dedup();
        assert_eq!(names, OP_NAMES);
        for op in ops {
            let e = ev(op);
            let raw = RawEnvelope::parse(&e.to_line()).unwrap();
            assert_eq!(Event::from_raw(raw).unwrap(), e);
        }
    }

    #[test]
    fn unknown_op_and_extra_fields() {
        assert_eq!(
            Op::from_parts("frobnicate", serde_json::json!({})),
            Err(OpError::Unknown("frobnicate".into()))
        );
        let op = Op::from_parts(
            "status",
            serde_json::json!({"to": "doing", "why": "later field"}),
        );
        assert_eq!(op, Ok(Op::Status(TextTo { to: "doing".into() })));
    }

    #[test]
    fn nullable_fields_must_be_present() {
        assert!(matches!(
            Op::from_parts("doc", serde_json::json!({"name": "d", "blob": "b"})),
            Err(OpError::Invalid(_))
        ));
        assert!(
            Op::from_parts(
                "doc",
                serde_json::json!({"name": "d", "blob": "b", "base": null})
            )
            .is_ok()
        );
        assert!(matches!(
            Op::from_parts("parent", serde_json::json!({})),
            Err(OpError::Invalid(_))
        ));
        assert!(matches!(
            Op::from_parts("archive", serde_json::json!([])),
            Err(OpError::Invalid(_))
        ));
        assert!(matches!(
            Op::from_parts("unarchive", serde_json::json!([])),
            Err(OpError::Invalid(_))
        ));
    }
}

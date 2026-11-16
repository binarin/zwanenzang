//! `zwanenzang.toml`: the tracker configuration.

use std::collections::BTreeMap;

use serde::Deserialize;

use crate::names::{valid_name, valid_prefix};
use crate::ulid::Ulid;

pub const CONFIG_FILE: &str = "zwanenzang.toml";

pub const DEFAULT_STATUSES: &[&str] = &["todo", "next", "wait", "agnt", "revw", "done", "cncl"];
pub const DEFAULT_KINDS: &[&str] = &["task", "bug", "feature"];
/// The identity agents write as, in every list `init` writes.
pub const AGENT_IDENTITY: &str = "agent";
/// The identity an import writes as. Reserved: accepted whatever `actors`
/// says, so an import needs no configuration.
pub const IMPORT_IDENTITY: &str = "import";

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct RepoConfig {
    pub url: String,
}

/// Native Org priority values: numbers 0..=64, then character codes A..=Z.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, serde::Serialize)]
#[serde(default, deny_unknown_fields)]
pub struct PriorityConfig {
    pub highest: u8,
    pub lowest: u8,
    pub default: u8,
}

impl Default for PriorityConfig {
    fn default() -> Self {
        Self {
            highest: b'A',
            lowest: b'C',
            default: b'B',
        }
    }
}

impl PriorityConfig {
    pub fn contains(&self, value: u8) -> bool {
        (self.highest..=self.lowest).contains(&value)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct Config {
    /// The tracker root entity.
    pub id: Ulid,
    pub name: String,
    pub prefix: String,
    pub statuses: Vec<String>,
    /// Statuses kept so old events replay, but refused in new writes.
    /// Each is also in `statuses`.
    #[serde(default)]
    pub retired_statuses: Vec<String>,
    #[serde(default)]
    pub kinds: Vec<String>,
    /// The identities writes may name with `--actor-name`. Without the key
    /// any identity in the vocabulary format is accepted.
    #[serde(default)]
    pub actors: Option<Vec<String>>,
    #[serde(default)]
    pub repos: BTreeMap<String, RepoConfig>,
    #[serde(default)]
    pub priority: PriorityConfig,
}

impl Config {
    pub fn new(id: Ulid, name: &str, prefix: &str) -> Config {
        Config {
            id,
            name: name.to_string(),
            prefix: prefix.to_string(),
            statuses: DEFAULT_STATUSES.iter().map(|s| s.to_string()).collect(),
            retired_statuses: Vec::new(),
            kinds: DEFAULT_KINDS.iter().map(|s| s.to_string()).collect(),
            actors: Some(vec![AGENT_IDENTITY.to_string()]),
            repos: BTreeMap::new(),
            priority: PriorityConfig::default(),
        }
    }

    /// [`Config::new`] whose `actors` list starts with `actor`, the name
    /// `init` was given, when there is one.
    pub fn new_with_actor(id: Ulid, name: &str, prefix: &str, actor: Option<&str>) -> Config {
        let mut c = Config::new(id, name, prefix);
        if let (Some(a), Some(list)) = (actor, c.actors.as_mut())
            && !list.iter().any(|x| x == a)
        {
            list.insert(0, a.to_string());
        }
        c
    }

    /// The human-facing form of a ticket number: prefix, hyphen and the
    /// decimal number without padding, such as `ZZ-42`.
    pub fn number_text(&self, n: u64) -> String {
        format!("{}-{n}", self.prefix)
    }

    pub fn parse(text: &str) -> Result<Config, String> {
        let c: Config = toml::from_str(text).map_err(|e| e.to_string())?;
        c.validate()?;
        Ok(c)
    }

    pub fn validate(&self) -> Result<(), String> {
        if self.priority.lowest > b'Z' || !self.priority.contains(self.priority.default) {
            return Err("priority requires 0 <= highest <= default <= lowest <= 90".into());
        }
        if !valid_prefix(&self.prefix) {
            return Err(format!(
                "prefix {:?} must be an uppercase letter followed by up to nine uppercase letters or digits",
                self.prefix
            ));
        }
        if self.name.trim().is_empty() || self.name.contains(['\n', '\r']) {
            return Err("name must be a non-empty single line".into());
        }
        if self.statuses.is_empty() {
            return Err("statuses must not be empty".into());
        }
        let no_actors = Vec::new();
        for (what, list) in [
            ("status", &self.statuses),
            ("retired status", &self.retired_statuses),
            ("kind", &self.kinds),
            ("actor", self.actors.as_ref().unwrap_or(&no_actors)),
        ] {
            let mut seen = std::collections::BTreeSet::new();
            for s in list {
                if !valid_name(s) {
                    return Err(format!("invalid {what} {s:?}"));
                }
                if !seen.insert(s) {
                    return Err(format!("duplicate {what} {s:?}"));
                }
            }
        }
        for s in &self.retired_statuses {
            if !self.statuses.contains(s) {
                return Err(format!("retired status {s:?} is not in statuses"));
            }
        }
        if self.is_retired(&self.statuses[0]) {
            return Err(format!(
                "the first status {:?} is the default for new tickets and cannot be retired",
                self.statuses[0]
            ));
        }
        for (alias, repo) in &self.repos {
            if !valid_name(alias) {
                return Err(format!("invalid repository alias {alias:?}"));
            }
            if repo.url.trim().is_empty() {
                return Err(format!("repository {alias:?} has an empty url"));
            }
        }
        Ok(())
    }

    /// Whether a write may name identity `name`: one of `actors`, or any
    /// name in the vocabulary format when the key is absent, and always
    /// [`IMPORT_IDENTITY`].
    pub fn accepts_identity(&self, name: &str) -> bool {
        name == IMPORT_IDENTITY
            || match &self.actors {
                Some(list) => list.iter().any(|a| a == name),
                None => valid_name(name),
            }
    }

    /// Whether new writes must not use status `s`.
    pub fn is_retired(&self, s: &str) -> bool {
        self.retired_statuses.iter().any(|r| r == s)
    }

    /// Renders the configuration as written by `init`.
    pub fn to_toml(&self) -> String {
        let q = |s: &str| toml::Value::String(s.to_string()).to_string();
        let list = |v: &[String]| {
            let items: Vec<String> = v.iter().map(|s| q(s)).collect();
            format!("[{}]", items.join(", "))
        };
        let mut out = String::new();
        out.push_str("# zwanenzang tracker configuration.\n\n");
        out.push_str("# The tracker root entity. Never change it.\n");
        out.push_str(&format!("id = {}\n", q(&self.id.to_canonical())));
        out.push_str(&format!("name = {}\n", q(&self.name)));
        out.push_str("# Ticket numbers display as <prefix>-N.\n");
        out.push_str(&format!("prefix = {}\n\n", q(&self.prefix)));
        out.push_str("# Vocabularies may grow; removing a name breaks old events that use it.\n");
        out.push_str("# The first status is the default for new tickets.\n");
        out.push_str(&format!("statuses = {}\n", list(&self.statuses)));
        out.push_str("# Statuses from the list above that old events keep using but new\n");
        out.push_str("# writes refuse. Retire a name instead of removing it.\n");
        out.push_str(&format!(
            "retired_statuses = {}\n",
            list(&self.retired_statuses)
        ));
        out.push_str(&format!("kinds = {}\n\n", list(&self.kinds)));
        if let Some(actors) = &self.actors {
            out.push_str("# Identities a write may name with --actor-name. Agents write as\n");
            out.push_str(&format!("# {AGENT_IDENTITY:?}; imports write as {IMPORT_IDENTITY:?}, which need not be listed.\n"));
            out.push_str(&format!("actors = {}\n\n", list(actors)));
        }
        out.push_str("# Native Org priority values: 0..64 numeric, 65..90 letters A..Z.\n");
        out.push_str(&format!(
            "[priority]\nhighest = {}\nlowest = {}\ndefault = {}\n\n",
            self.priority.highest, self.priority.lowest, self.priority.default
        ));
        out.push_str("# Repository aliases named by branch and mr events, for example:\n");
        out.push_str("# [repos.app]\n# url = \"https://forge.example/owner/app\"\n");
        for (alias, repo) in &self.repos {
            out.push_str(&format!("\n[repos.{alias}]\nurl = {}\n", q(&repo.url)));
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip() {
        let mut c = Config::new(Ulid::from_parts(1, 2), "My \"tracker\"", "ZZ");
        c.repos.insert(
            "app".into(),
            RepoConfig {
                url: "https://example.org/app".into(),
            },
        );
        let parsed = Config::parse(&c.to_toml()).unwrap();
        assert_eq!(parsed, c);
    }

    #[test]
    fn rejects_bad_values() {
        let base = Config::new(Ulid::from_parts(1, 2), "t", "ZZ");
        let mut c = base.clone();
        c.prefix = "zz".into();
        assert!(c.validate().is_err());
        let mut c = base.clone();
        c.statuses.clear();
        assert!(c.validate().is_err());
        let mut c = base.clone();
        c.statuses.push("todo".into());
        assert!(c.validate().is_err());
        let mut c = base;
        c.kinds.push("has space".into());
        assert!(c.validate().is_err());
        assert!(Config::parse("name = \"x\"").is_err());
    }

    #[test]
    fn default_vocabulary() {
        let c = Config::new(Ulid::from_parts(1, 2), "t", "ZZ");
        assert_eq!(
            c.statuses,
            ["todo", "next", "wait", "agnt", "revw", "done", "cncl"]
        );
        assert!(c.retired_statuses.is_empty());
        assert!(c.to_toml().contains("\nretired_statuses = []\n"));
    }

    #[test]
    fn actors() {
        let mut c = Config::new(Ulid::from_parts(1, 2), "t", "ZZ");
        assert_eq!(c.actors, Some(vec!["agent".to_string()]));
        assert!(c.to_toml().contains("\nactors = [\"agent\"]\n"));
        c.actors = Some(vec!["binarin".into(), "agent".into()]);
        assert_eq!(Config::parse(&c.to_toml()).unwrap(), c);
        assert!(c.accepts_identity("binarin"));
        assert!(c.accepts_identity("import"));
        assert!(!c.accepts_identity("tester"));

        let mut bad = c.clone();
        bad.actors = Some(vec!["agent".into(), "agent".into()]);
        assert!(bad.validate().unwrap_err().contains("duplicate actor"));
        let mut bad = c;
        bad.actors = Some(vec!["has space".into()]);
        assert!(bad.validate().unwrap_err().contains("invalid actor"));

        // An older configuration without the key accepts any name in the
        // vocabulary format.
        let old = "id = \"01M6Y59XPNBPDNXM61N9YN9G5J\"\nname = \"t\"\nprefix = \"ZZ\"\n\
                   statuses = [\"todo\"]\n";
        let old = Config::parse(old).unwrap();
        assert_eq!(old.actors, None);
        assert!(old.accepts_identity("tester"));
        assert!(!old.accepts_identity("has space"));
        assert!(!old.to_toml().contains("actors ="));
    }

    #[test]
    fn retired_statuses() {
        let mut c = Config::new(Ulid::from_parts(1, 2), "t", "ZZ");
        c.statuses.push("doing".into());
        c.retired_statuses.push("doing".into());
        assert_eq!(c.validate(), Ok(()));
        assert!(c.is_retired("doing"));
        assert!(!c.is_retired("agnt"));
        assert_eq!(Config::parse(&c.to_toml()).unwrap(), c);

        let mut bad = c.clone();
        bad.retired_statuses.push("parked".into());
        assert!(bad.validate().unwrap_err().contains("not in statuses"));
        let mut bad = c.clone();
        bad.retired_statuses.push("doing".into());
        assert!(bad.validate().unwrap_err().contains("duplicate"));
        let mut bad = c;
        bad.retired_statuses.push("todo".into());
        assert!(bad.validate().unwrap_err().contains("cannot be retired"));

        // An older configuration without the key retires nothing.
        let old = "id = \"01M6Y59XPNBPDNXM61N9YN9G5J\"\nname = \"t\"\nprefix = \"ZZ\"\n\
                   statuses = [\"draft\", \"doing\"]\n";
        assert!(Config::parse(old).unwrap().retired_statuses.is_empty());
    }
}

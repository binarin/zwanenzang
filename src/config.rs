//! `zwanenzang.toml`: the tracker configuration.

use std::collections::BTreeMap;

use serde::Deserialize;

use crate::names::{valid_name, valid_prefix};
use crate::ulid::Ulid;

pub const CONFIG_FILE: &str = "zwanenzang.toml";

pub const DEFAULT_STATUSES: &[&str] = &[
    "draft",
    "todo",
    "doing",
    "blocked",
    "review",
    "done",
    "cancelled",
];
pub const DEFAULT_KINDS: &[&str] = &["task", "bug", "feature"];

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct RepoConfig {
    pub url: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct Config {
    /// The tracker root entity.
    pub id: Ulid,
    pub name: String,
    pub prefix: String,
    pub statuses: Vec<String>,
    #[serde(default)]
    pub kinds: Vec<String>,
    #[serde(default)]
    pub repos: BTreeMap<String, RepoConfig>,
}

impl Config {
    pub fn new(id: Ulid, name: &str, prefix: &str) -> Config {
        Config {
            id,
            name: name.to_string(),
            prefix: prefix.to_string(),
            statuses: DEFAULT_STATUSES.iter().map(|s| s.to_string()).collect(),
            kinds: DEFAULT_KINDS.iter().map(|s| s.to_string()).collect(),
            repos: BTreeMap::new(),
        }
    }

    pub fn parse(text: &str) -> Result<Config, String> {
        let c: Config = toml::from_str(text).map_err(|e| e.to_string())?;
        c.validate()?;
        Ok(c)
    }

    pub fn validate(&self) -> Result<(), String> {
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
        for (what, list) in [("status", &self.statuses), ("kind", &self.kinds)] {
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
        out.push_str("# Ticket numbers display as <prefix>-NNNN.\n");
        out.push_str(&format!("prefix = {}\n\n", q(&self.prefix)));
        out.push_str("# Vocabularies may grow; removing a name breaks old events that use it.\n");
        out.push_str("# The first status is the default for new tickets.\n");
        out.push_str(&format!("statuses = {}\n", list(&self.statuses)));
        out.push_str(&format!("kinds = {}\n\n", list(&self.kinds)));
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
        c.statuses.push("draft".into());
        assert!(c.validate().is_err());
        let mut c = base;
        c.kinds.push("has space".into());
        assert!(c.validate().is_err());
        assert!(Config::parse("name = \"x\"").is_err());
    }
}

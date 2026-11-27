//! Lint: everything replay skipped, plus the reports that are not errors.

use serde_json::{Value, json};

use crate::config::{Config, OBSOLETE_STATUSES_KEY};
use crate::event::Op;
use crate::replay::Replay;

/// Returns the lint report and whether it found any issue.
pub fn lint(config: &Config, rp: &Replay) -> (Value, bool) {
    let mut dangling = Vec::new();
    for ev in &rp.events {
        let repo = match &ev.op {
            Op::Branch(d) => &d.repo,
            Op::Mr(d) => &d.repo,
            _ => continue,
        };
        if !config.repos.contains_key(repo) {
            dangling.push(json!({
                "event": ev.id,
                "entity": ev.entity,
                "op": ev.op.name(),
                "repo": repo,
            }));
        }
    }
    // Writers with events that resolve to no identity: no `as`, and no
    // declared name to fall back on.
    let unnamed: Vec<Value> = rp
        .state
        .actors
        .iter()
        .filter(|(_, a)| a.name.is_none() && a.without_identity > 0)
        .map(|(id, a)| json!({"actor": id, "events": a.without_identity}))
        .collect();
    let unknown_identities: Vec<Value> = rp
        .events
        .iter()
        .filter_map(|ev| {
            let name = ev.identity.as_deref()?;
            (!config.accepts_identity(name))
                .then(|| json!({"event": ev.id, "actor": ev.actor, "as": name, "op": ev.op.name()}))
        })
        .collect();
    // Keys `zwanenzang.toml` may still carry that nothing reads any more.
    let obsolete_keys: Vec<&str> = config
        .obsolete_statuses
        .is_some()
        .then_some(OBSOLETE_STATUSES_KEY)
        .into_iter()
        .collect();
    let dependency_cycles = rp.state.dependency_cycles();
    let proj_open = rp.state.proj_open_descendants();
    let issues = !dependency_cycles.is_empty()
        || !proj_open.is_empty()
        || !rp.skipped.is_empty()
        || !rp.state.concurrent.is_empty()
        || !rp.state.lost_docs.is_empty()
        || !dangling.is_empty()
        || !unnamed.is_empty()
        || !unknown_identities.is_empty()
        || !obsolete_keys.is_empty();
    let report = json!({
        "ok": !issues,
        "events": rp.events.len(),
        "skipped": rp.skipped,
        "concurrent": rp.state.concurrent,
        "lost_documents": rp.state.lost_docs,
        "dependency_cycles": dependency_cycles,
        "proj_open_descendants": proj_open,
        "dangling_repos": dangling,
        "unnamed_actors": unnamed,
        "unknown_identities": unknown_identities,
        "obsolete_config_keys": obsolete_keys,
    });
    (report, issues)
}

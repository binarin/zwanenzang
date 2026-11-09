//! Lint: everything replay skipped, plus the reports that are not errors.

use serde_json::{Value, json};

use crate::config::Config;
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
    let unnamed: Vec<Value> = rp
        .state
        .actors
        .iter()
        .filter(|(_, a)| a.name.is_none())
        .map(|(id, a)| json!({"actor": id, "events": a.events}))
        .collect();
    let dependency_cycles = rp.state.dependency_cycles();
    let issues = !dependency_cycles.is_empty()
        || !rp.skipped.is_empty()
        || !rp.state.concurrent.is_empty()
        || !rp.state.lost_docs.is_empty()
        || !dangling.is_empty()
        || !unnamed.is_empty();
    let report = json!({
        "ok": !issues,
        "events": rp.events.len(),
        "skipped": rp.skipped,
        "concurrent": rp.state.concurrent,
        "lost_documents": rp.state.lost_docs,
        "dependency_cycles": dependency_cycles,
        "dangling_repos": dangling,
        "unnamed_actors": unnamed,
    });
    (report, issues)
}

//! The workflow vocabulary, fixed in code rather than configured: the
//! statuses and the tags that carry workflow. Their meaning is
//! `docs/agent-hooks/tickets/statuses.md`.

use std::collections::BTreeSet;

/// The statuses every tracker has. The first is the default for new
/// tickets. A tracker adds only names it keeps for old events, its
/// `retired_statuses`.
pub const STATUSES: [&str; 7] = ["todo", "next", "wait", "agnt", "revw", "done", "cncl"];
/// The status of a ticket created without one.
pub const DEFAULT_STATUS: &str = STATUSES[0];
/// Ready for the human's review; always paired with [`NEEDS_HUMAN_TAG`].
pub const REVIEW_STATUS: &str = "revw";

/// Standing permission for an agent to pick the ticket up on its own.
pub const READY_FOR_AGENT_TAG: &str = "ready_for_agent";
/// An agent is waiting on the human.
pub const NEEDS_HUMAN_TAG: &str = "needs_human";
/// The tag that makes a ticket a project, whose status follows its
/// subtree. Hard-coded: see `01-data-model.md`.
pub const PROJ_TAG: &str = "PROJ";

/// What a ticket with `status` and `tags` lacks of the pairings
/// `tickets/statuses` states: only `revw` without `needs_human`. Writes
/// that leave it are warned about, never refused, so a manual edit from
/// Org is not blocked.
pub fn missing_pairing(status: &str, tags: &BTreeSet<String>) -> Option<String> {
    (status == REVIEW_STATUS && !tags.contains(NEEDS_HUMAN_TAG))
        .then(|| format!("status {REVIEW_STATUS} without tag {NEEDS_HUMAN_TAG}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tags(names: &[&str]) -> BTreeSet<String> {
        names.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn review_needs_the_human_tag() {
        assert_eq!(
            missing_pairing("revw", &tags(&["ui"])).as_deref(),
            Some("status revw without tag needs_human")
        );
        assert_eq!(missing_pairing("revw", &tags(&["needs_human"])), None);
        // `needs_human` is optional with `wait`, and any status may go
        // without it.
        assert_eq!(missing_pairing("wait", &tags(&[])), None);
        assert_eq!(missing_pairing("agnt", &tags(&["ready_for_agent"])), None);
    }
}

//! Agent instructions bundled with the executable, served by logical name.
//! The table is generated from `docs/agent-hooks/` by `build.rs`; lookups
//! never touch the filesystem, so a name cannot reach anything outside it.

include!(concat!(env!("OUT_DIR"), "/agent_hooks.rs"));

/// The command an agent runs to read a bundled document.
pub const SHOW: &str = "zz agent-hooks show-document";

/// The text of the document `name`, if the bundle has one.
pub fn document(name: &str) -> Option<&'static str> {
    DOCUMENTS
        .iter()
        .find(|(n, _)| *n == name)
        .map(|(_, text)| *text)
}

/// Every document name, sorted.
pub fn names() -> impl Iterator<Item = &'static str> {
    DOCUMENTS.iter().map(|(n, _)| *n)
}

/// The immediate subtopics of the landing document `dir`; `None` is the
/// root, whose landing document is `overview`.
pub fn children(dir: Option<&str>) -> Vec<&'static str> {
    names()
        .filter(|n| match dir {
            None => *n != "overview" && !n.contains('/'),
            Some(d) => n
                .strip_prefix(d)
                .and_then(|rest| rest.strip_prefix('/'))
                .is_some_and(|rest| !rest.contains('/')),
        })
        .collect()
}

/// Whether `name` is a landing document with subtopics.
pub fn is_landing(name: &str) -> bool {
    !children(Some(name)).is_empty()
}

/// The document `name`, or a message listing the subtopics of its nearest
/// known landing document (the top-level topics when there is none).
pub fn show(name: &str) -> Result<&'static str, String> {
    if let Some(text) = document(name) {
        return Ok(text);
    }
    let parent = std::iter::successors(name.rsplit_once('/').map(|(p, _)| p), |p| {
        p.rsplit_once('/').map(|(p, _)| p)
    })
    .find(|p| is_landing(p));
    let mut message = format!("no agent document named {name:?}; ");
    match parent {
        Some(p) => message.push_str(&format!("topics under {p:?}:\n")),
        None => message.push_str(&format!("start with `{SHOW} overview`, or a topic:\n")),
    }
    for child in children(parent) {
        message.push_str(&format!("  {SHOW} {child}\n"));
    }
    Err(message)
}

/// The paragraph a project pastes into its agent instructions. It names the
/// tracker's prefix and the entry point, nothing machine-local.
pub fn bootstrap(prefix: &str) -> String {
    let lower = prefix.to_ascii_lowercase();
    format!(
        "This project's tickets are kept in a zwanenzang tracker. A ticket id is\n\
         the prefix `{prefix}`, a hyphen and a number, such as `{prefix}-42`; letter\n\
         case and leading zeros do not matter, so `{lower}-0042` is the same ticket.\n\
         Before reading or changing tickets, including when a task mentions such\n\
         an id, run `{SHOW} overview` and follow it.\n"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every `zz agent-hooks show-document NAME` mentioned in `text`.
    fn references(text: &str) -> Vec<&str> {
        let mut out = Vec::new();
        // Commands may be wrapped across a line break inside backquotes.
        let flat: Vec<&str> = text.split_whitespace().collect();
        let words: Vec<&str> = SHOW.split(' ').collect();
        for w in flat.windows(words.len() + 1) {
            let head: Vec<&str> = w[..words.len()]
                .iter()
                .map(|s| s.trim_start_matches('`'))
                .collect();
            if head == words {
                out.push(w[words.len()].trim_end_matches(['`', '.', ',', ':', ';', ')']));
            }
        }
        out
    }

    #[test]
    fn landing_names_follow_directories() {
        assert!(document("overview").is_some());
        assert!(document("tickets").is_some());
        assert!(document("tickets/reading").is_some());
        assert!(document("tickets/conflicts").is_some());
        assert!(document("tickets/conflicts/stale-doc-base").is_some());
        for missing in [
            "tickets/overview",
            "tickets/reading.md",
            "overview.md",
            "",
            "/overview",
            "../overview",
            "tickets/../overview",
            "./overview",
        ] {
            assert!(document(missing).is_none(), "{missing}");
        }
        assert_eq!(children(None), ["cli-json", "selection", "tickets"]);
        assert!(
            children(Some("tickets"))
                .iter()
                .all(|c| c.starts_with("tickets/") && c.matches('/').count() == 1)
        );
        assert!(children(Some("tickets")).contains(&"tickets/conflicts"));
        assert!(!children(Some("tickets")).contains(&"tickets/conflicts/stale-doc-base"));
    }

    #[test]
    fn unknown_names_list_the_nearest_landing() {
        let e = show("tickets/conflicts/nope").unwrap_err();
        assert!(e.contains("\"tickets/conflicts\""), "{e}");
        assert!(e.contains(&format!("{SHOW} tickets/conflicts/stale-doc-base\n")));
        assert!(!e.contains(&format!("{SHOW} tickets/reading\n")));
        // A leaf is not a landing: its siblings are listed.
        let e = show("tickets/reading/deeper").unwrap_err();
        assert!(e.contains(&format!("{SHOW} tickets/reading\n")), "{e}");
        assert!(!e.contains("stale-doc-base"), "{e}");
        for top in ["nope", "../../etc/passwd", "/etc/passwd", "nope/tickets"] {
            let e = show(top).unwrap_err();
            assert!(e.contains(&format!("{SHOW} tickets\n")), "{e}");
            assert!(!e.contains("tickets/"), "{e}");
        }
    }

    #[test]
    fn references_resolve_and_landings_list_exactly_their_children() {
        for (name, text) in DOCUMENTS {
            for r in references(text) {
                assert!(document(r).is_some(), "{name} refers to unknown {r:?}");
            }
            let landing = if *name == "overview" {
                None
            } else if is_landing(name) {
                Some(*name)
            } else {
                continue;
            };
            let mut listed: Vec<&str> = references(text)
                .into_iter()
                .filter(|r| match landing {
                    None => *r != "overview",
                    Some(d) => r.starts_with(&format!("{d}/")),
                })
                .collect();
            listed.sort();
            listed.dedup();
            assert_eq!(listed, children(landing), "{name} lists other topics");
        }
    }

    #[test]
    fn bundle_holds_no_paths_versions_or_file_links() {
        for (name, text) in DOCUMENTS {
            for bad in [
                "/nix/store",
                "docs/",
                "design/",
                ".md)",
                "agents.md",
                "AGENTS.md",
                "SKILL",
                "/home/",
                env!("CARGO_PKG_VERSION"),
            ] {
                // `AGENTS.md` may be mentioned in the contract as where a
                // project pastes its bootstrap, never as a link.
                if *name == "cli-json" && matches!(bad, "AGENTS.md" | "docs/") {
                    continue;
                }
                assert!(!text.contains(bad), "{name} contains {bad:?}");
            }
            let mut rest = *text;
            while let Some(i) = rest.find("](") {
                rest = &rest[i + 2..];
                assert!(
                    rest.starts_with('#') || rest.starts_with("http"),
                    "{name} links to a file: {}",
                    &rest[..rest.len().min(40)]
                );
            }
        }
    }

    #[test]
    fn bootstrap_names_prefix_and_entry_point_only() {
        let b = bootstrap("ZZ");
        assert!(b.contains("`ZZ-42`") && b.contains("`zz-0042`"));
        assert!(b.contains("zz agent-hooks show-document overview"));
        // No path of any kind: nothing machine-local or store-bound.
        assert!(!b.contains('/'), "{b}");
    }
}

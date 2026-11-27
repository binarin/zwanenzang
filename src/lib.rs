//! zwanenzang core: event log, replay and derived state.
//!
//! - [`event`]: the envelope and typed operations, one JSON object per line.
//! - [`ulid`], [`clock`]: ids and the hybrid logical clock.
//! - [`planning`]: Org planning timestamps, the `scheduled` field's values.
//! - [`config`], [`store`]: `zwanenzang.toml`, logs, blobs, actor id, lock.
//! - [`workflow`]: the fixed statuses and workflow tags.
//! - [`git`], [`sync`]: commit per write, fetch, rebase, numbering, push.
//! - [`state`]: derived state and [`state::apply`], the single validation
//!   and application rule shared by replay and live writes.
//! - [`replay`], [`write`]: reading everything back, and appending.
//! - [`view`], [`lint`], [`cli`]: JSON output and the command line.
//! - [`render`], [`org`]: the static HTML site and its Org renderer.
//! - [`agent_hooks`]: agent instructions bundled from `docs/agent-hooks/`.

pub mod agent_hooks;
pub mod batch;
pub mod checkout;
pub mod cli;
pub mod clock;
pub mod config;
pub mod error;
pub mod event;
pub mod frontmatter;
pub mod git;
pub mod import;
pub mod init;
pub mod lint;
mod locator;
pub mod names;
pub mod org;
pub mod planning;
pub mod read;
pub mod render;
pub mod replay;
pub mod state;
pub mod store;
pub mod sync;
pub mod ulid;
pub mod view;
pub mod workflow;
pub mod write;

#[cfg(test)]
mod tests;

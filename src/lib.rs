//! zwanenzang core: event log, replay and derived state.
//!
//! - [`event`]: the envelope and typed operations, one JSON object per line.
//! - [`ulid`], [`clock`]: ids and the hybrid logical clock.
//! - [`config`], [`store`]: `zwanenzang.toml`, logs, blobs, actor id, lock.
//! - [`state`]: derived state and [`state::apply`], the single validation
//!   and application rule shared by replay and live writes.
//! - [`replay`], [`write`]: reading everything back, and appending.
//! - [`view`], [`lint`], [`cli`]: JSON output and the command line.

pub mod cli;
pub mod clock;
pub mod config;
pub mod error;
pub mod event;
pub mod lint;
pub mod names;
pub mod replay;
pub mod state;
pub mod store;
pub mod ulid;
pub mod view;
pub mod write;

#[cfg(test)]
mod tests;

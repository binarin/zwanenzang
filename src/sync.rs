//! Publishing a clone's commits: fetch the upstream branch, rebase onto it,
//! give every unnumbered ticket the next number, and push. A rejected push
//! drops this clone's unpushed numbers, which nobody has seen, and starts
//! over, a bounded number of times. Without an upstream the clone is the
//! whole tracker and numbers are assigned at once.

use std::path::PathBuf;

use serde::Serialize;

use crate::checkout::{self, CheckoutUpdates};
use crate::clock::Clock;
use crate::error::{Error, Result};
use crate::event::{NumberData, Op};
use crate::git::{Identity, Push, Repo};
use crate::names::valid_actor_name;
use crate::store::{Tracker, lock_repo};
use crate::ulid::Ulid;
use crate::write::{Plan, Target, WriteOptions};

/// Fetch, rebase and push rounds before giving up on a contended remote.
pub const ATTEMPTS: u32 = 5;

/// A random pause before attempt `n` (from 1), up to 50 ms doubled per
/// attempt, so writers that keep colliding drift apart.
fn backoff(n: u32) {
    let mut buf = [0u8; 2];
    getrandom::fill(&mut buf).expect("operating system random source");
    let cap = 50u64 << n.min(6);
    let ms = u64::from(u16::from_le_bytes(buf)) % cap;
    std::thread::sleep(std::time::Duration::from_millis(ms));
}

#[derive(Debug, Clone, Serialize)]
pub struct SyncError {
    pub code: &'static str,
    pub message: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct Numbered {
    /// The ticket.
    pub id: Ulid,
    pub number: u64,
    pub display: String,
    /// The `number` event.
    pub event: Ulid,
}

/// What a sync did. A failure to reach the remote or to rebase is reported
/// here rather than as an error: the write before it is committed locally
/// and is pushed by a later sync.
#[derive(Debug, Clone, Default, Serialize)]
pub struct SyncReport {
    /// `remote/branch`, or `None` when the branch has no upstream.
    pub upstream: Option<String>,
    pub pushed: bool,
    /// Numbers assigned and, with an upstream, pushed.
    pub numbered: Vec<Numbered>,
    pub error: Option<SyncError>,
    pub checkouts: CheckoutUpdates,
}

impl SyncReport {
    fn fail(&mut self, code: &'static str, message: impl Into<String>) -> Result<SyncReport> {
        self.error = Some(SyncError {
            code,
            message: message.into(),
        });
        Ok(self.clone())
    }
}

/// The commit identity of a writer: `name` (the identity of the write, or
/// the writer's declared name), else the writer id, and an address made
/// from the writer id.
pub fn identity(actor: Ulid, name: Option<String>) -> Identity {
    let name = name
        .filter(|n| valid_actor_name(n))
        .unwrap_or_else(|| actor.to_string());
    Identity {
        name,
        email: format!("{actor}@zwanenzang.invalid"),
    }
}

impl Tracker {
    /// Publishes under the tracker lock; the `sync` command. `actor_name`
    /// is the identity of the `number` events it writes, as for
    /// [`Tracker::write`]; a sync with nothing to number needs none.
    pub fn sync(&self, clock: &mut dyn Clock, actor_name: Option<&str>) -> Result<SyncReport> {
        let repo = self.repo()?;
        let _lock = lock_repo(&repo)?;
        self.sync_locked(&repo, clock, actor_name)
    }

    /// The clone actor's commit identity, if the clone has an actor yet.
    fn clone_identity(&self, repo: &Repo, clock: &mut dyn Clock) -> Result<Identity> {
        let actor = self.actor_in(repo, true, clock)?.expect("created");
        let rp = self.load()?;
        let name = rp.state.actors.get(&actor).and_then(|a| a.name.clone());
        Ok(identity(actor, name))
    }

    pub(crate) fn sync_locked(
        &self,
        repo: &Repo,
        clock: &mut dyn Clock,
        actor_name: Option<&str>,
    ) -> Result<SyncReport> {
        let mut target = None;
        let mut report = self.publish_locked(repo, clock, actor_name, &mut target)?;
        report.checkouts = checkout::update(repo, target);
        Ok(report)
    }

    fn publish_locked(
        &self,
        repo: &Repo,
        clock: &mut dyn Clock,
        actor_name: Option<&str>,
        target: &mut Option<String>,
    ) -> Result<SyncReport> {
        // Lines an interrupted command appended but did not commit.
        let id = self.clone_identity(repo, clock)?;
        repo.commit(
            &[PathBuf::from("events"), PathBuf::from("blobs")],
            "commit events left uncommitted",
            &id,
        )?;

        let mut report = SyncReport::default();
        let Some(up) = repo.upstream()? else {
            report.numbered = self.publish_numbers(repo, clock, actor_name)?;
            *target = Some(repo.head()?);
            return Ok(report);
        };
        report.upstream = Some(up.display());
        for attempt in 0..ATTEMPTS {
            if attempt > 0 {
                backoff(attempt);
            }
            let fetched = match repo.fetch(&up)? {
                Ok(f) => f,
                Err(m) => return report.fail("fetch-failed", m),
            };
            // Keep the last successful observation across retries, even if
            // a later fetch fails. Never substitute a rebased local HEAD.
            *target = fetched.clone();
            if let Some(commit) = fetched
                && let Err(m) = repo.rebase(&commit, &id)?
            {
                return report.fail("rebase-conflict", m);
            }
            let numbered = self.publish_numbers(repo, clock, actor_name)?;
            let pushing = repo.head()?;
            let push = repo.push(&up)?;
            if !matches!(push, Push::Done) && !numbered.is_empty() {
                // Unpushed numbers would collide with whatever the remote
                // assigns meanwhile; they are assigned again after the next
                // fetch.
                repo.undo_last_commit()?;
            }
            match push {
                Push::Done => {
                    *target = Some(pushing);
                    report.pushed = true;
                    report.numbered = numbered;
                    return Ok(report);
                }
                Push::Rejected => continue,
                Push::Failed(m) => return report.fail("push-failed", m),
            }
        }
        report.fail(
            "push-rejected",
            format!("the remote kept moving; gave up after {ATTEMPTS} attempts"),
        )
    }

    /// Writes and commits a `number` event for every live ticket without
    /// one, in id order, continuing after the highest number in use.
    fn publish_numbers(
        &self,
        repo: &Repo,
        clock: &mut dyn Clock,
        actor_name: Option<&str>,
    ) -> Result<Vec<Numbered>> {
        let opts = WriteOptions {
            actor_name,
            ..WriteOptions::default()
        };
        let mut numbered = Vec::new();
        let (w, _) = self.write_locked(
            repo,
            clock,
            opts,
            |rp| {
                let mut next = rp.state.numbers.keys().max().map_or(1, |n| n + 1);
                let mut plan = Plan::default();
                for t in rp.state.tickets.values() {
                    if t.tombstoned || t.number.is_some() {
                        continue;
                    }
                    numbered.push(Numbered {
                        id: t.id,
                        number: next,
                        display: self.config.number_text(next),
                        event: Ulid(0),
                    });
                    plan.ops.push((
                        Target::Entity(t.id),
                        Op::Number(NumberData { number: next }),
                    ));
                    next += 1;
                }
                Ok(plan)
            },
            |_| Ok(Vec::new()),
        )?;
        if !w.written() {
            return Ok(Vec::new());
        }
        for n in &mut numbered {
            n.event = w
                .events
                .iter()
                .find(|e| e.entity == n.id && matches!(e.op, Op::Number(_)))
                .expect("every planned number changes state")
                .id;
        }
        let shown: Vec<&str> = numbered.iter().map(|n| n.display.as_str()).collect();
        let message = match shown.len() {
            1..=3 => format!("publish {}", shown.join(", ")),
            n => format!("publish {n} numbers"),
        };
        let actor = w.events[0].actor;
        if !repo.commit(
            &[PathBuf::from("events")],
            &message,
            &identity(actor, w.identity.clone()),
        )? {
            return Err(Error::Git(
                "numbers were written but nothing was committed".into(),
            ));
        }
        Ok(numbered)
    }
}

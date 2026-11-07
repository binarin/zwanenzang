//! The command line: argument definitions and dispatch. Every command prints
//! one JSON value on stdout.

use std::io::Read;
use std::path::{Path, PathBuf};

use clap::{Parser, Subcommand};
use serde_json::{Value, json};

use crate::clock::{Clock, SystemClock};
use crate::error::{Error, Result};
use crate::event::{
    BranchData, CommentData, CreateData, DocData, Empty, KindData, MrData, Op, ParentData,
    RelateData, TagData, TextTo,
};
use crate::lint::lint;
use crate::replay::Replay;
use crate::state::{RejectCode, Rejection};
use crate::store::{Tracker, blob_name, find_root};
use crate::ulid::Ulid;
use crate::view::View;
use crate::write::{Plan, Target, Written};

/// Comment text longer than this many bytes is stored as a blob.
pub const INLINE_COMMENT_LIMIT: usize = 2048;

#[derive(Debug, Parser)]
#[command(
    name = "zwanenzang",
    version,
    about = "A small, local-first issue tracker"
)]
pub struct Cli {
    /// Tracker directory; the tracker is searched for upward from it.
    /// Defaults to the current directory.
    #[arg(short = 'C', long = "tracker", global = true, value_name = "DIR")]
    pub tracker: Option<PathBuf>,
    /// Display name declared on this actor's first write.
    #[arg(long, global = true, value_name = "NAME")]
    pub actor_name: Option<String>,
    #[command(subcommand)]
    pub command: Command,
}

#[derive(Debug, Subcommand)]
pub enum Command {
    /// Create a tracker in the tracker directory (created if missing).
    Init {
        /// Number prefix, e.g. ZZ.
        #[arg(long)]
        prefix: String,
        /// Tracker name; defaults to the directory name.
        #[arg(long)]
        name: Option<String>,
    },
    /// Create a ticket.
    Create {
        title: String,
        /// Initial status; defaults to the first status in the vocabulary.
        #[arg(long)]
        status: Option<String>,
        #[arg(long)]
        kind: Option<String>,
        #[arg(long)]
        parent: Option<String>,
        #[arg(long = "tag", value_name = "TAG")]
        tags: Vec<String>,
    },
    /// Set a ticket's status.
    Status { ticket: String, status: String },
    /// Set a ticket's title.
    Title { ticket: String, title: String },
    /// Set or clear a ticket's kind.
    Kind {
        ticket: String,
        #[arg(required_unless_present = "clear")]
        kind: Option<String>,
        #[arg(long, conflicts_with = "kind")]
        clear: bool,
    },
    /// Set or clear a ticket's parent.
    Parent {
        ticket: String,
        #[arg(required_unless_present = "clear")]
        parent: Option<String>,
        #[arg(long, conflicts_with = "parent")]
        clear: bool,
    },
    /// Relate two tickets, or remove the relation.
    Relate {
        ticket: String,
        other: String,
        #[arg(long)]
        remove: bool,
    },
    /// Add or remove a tag.
    Tag {
        ticket: String,
        tag: String,
        #[arg(long)]
        remove: bool,
    },
    /// Reference a branch in a configured repository.
    Branch {
        ticket: String,
        repo: String,
        name: String,
    },
    /// Reference a merge request in a configured repository.
    Mr {
        ticket: String,
        repo: String,
        url: String,
    },
    /// Move a ticket out of the active set.
    Archive { ticket: String },
    /// Hide a ticket created by mistake.
    Tombstone { ticket: String },
    /// Add a comment; text from the argument, --file, or stdin.
    Comment {
        ticket: String,
        text: Option<String>,
        #[arg(long, conflicts_with = "text")]
        file: Option<PathBuf>,
        #[arg(long)]
        link: Option<String>,
    },
    /// Read or write a named document.
    Doc {
        #[command(subcommand)]
        command: DocCommand,
    },
    /// Show one ticket in full.
    Show { ticket: String },
    /// List ticket summaries.
    List {
        /// Only these statuses (repeatable; any of them).
        #[arg(long)]
        status: Vec<String>,
        /// Only tickets with these tags (repeatable; all of them).
        #[arg(long)]
        tag: Vec<String>,
        /// Only these kinds (repeatable; any of them).
        #[arg(long)]
        kind: Vec<String>,
        /// Include archived and tombstoned tickets.
        #[arg(long)]
        all: bool,
    },
    /// Report skipped events, concurrent changes, lost document edits,
    /// dangling repository aliases and unnamed actors. Exits 1 on issues.
    Lint,
    /// Import tickets from another tracker.
    Import {
        #[command(subcommand)]
        command: ImportCommand,
    },
}

#[derive(Debug, Subcommand)]
pub enum ImportCommand {
    /// Import the frozen ai-workflow tracker, written as a new actor named
    /// "ai-workflow import". Tickets already imported are skipped.
    AiWorkflow {
        /// The tracker checkout (holding tickets/ and docs/), or its
        /// tickets/ directory. Only read.
        source: PathBuf,
        /// Ticket ids to leave out, comma-separated (repeatable).
        #[arg(long, value_delimiter = ',', value_name = "IDS")]
        exclude: Vec<String>,
        /// A file of ticket ids to leave out, one per line; `#` starts a
        /// comment (repeatable).
        #[arg(long, value_name = "PATH")]
        exclude_file: Vec<PathBuf>,
        /// Use repository alias TO for the source's alias FROM
        /// (repeatable).
        #[arg(long = "repo-alias", value_name = "FROM=TO")]
        repo_alias: Vec<String>,
        /// Validate and report, write nothing.
        #[arg(long)]
        dry_run: bool,
    },
}

#[derive(Debug, Subcommand)]
pub enum DocCommand {
    /// Write a new version; text from --file or stdin.
    Set {
        ticket: String,
        name: String,
        /// The version id read before editing, or `none` for a new document.
        #[arg(long)]
        base: String,
        #[arg(long)]
        file: Option<PathBuf>,
    },
    /// Print the current version's text and id.
    Get { ticket: String, name: String },
}

/// Parses arguments, runs the command, prints its JSON and returns the exit
/// code.
pub fn main() -> i32 {
    let cli = Cli::parse();
    let (value, code) = run(cli, &mut SystemClock, &mut std::io::stdin());
    println!(
        "{}",
        serde_json::to_string_pretty(&value).expect("JSON values serialize")
    );
    code
}

/// Runs a parsed command. Returns the JSON to print and the exit code.
pub fn run(cli: Cli, clock: &mut dyn Clock, stdin: &mut dyn Read) -> (Value, i32) {
    match dispatch(cli, clock, stdin) {
        Ok(r) => r,
        Err(e) => (
            json!({"error": {"code": e.code(), "message": e.to_string()}}),
            1,
        ),
    }
}

fn read_text(file: Option<&Path>, stdin: &mut dyn Read) -> Result<String> {
    match file {
        Some(p) => std::fs::read_to_string(p).map_err(Error::io(p)),
        None => {
            let mut s = String::new();
            stdin.read_to_string(&mut s).map_err(Error::io("<stdin>"))?;
            Ok(s)
        }
    }
}

fn open(cli_dir: Option<&Path>) -> Result<Tracker> {
    let start = match cli_dir {
        Some(d) => d.to_path_buf(),
        None => std::env::current_dir().map_err(Error::io("."))?,
    };
    Tracker::open(&find_root(&start)?)
}

struct Ctx<'a> {
    tracker: Tracker,
    clock: &'a mut dyn Clock,
    actor_name: Option<String>,
}

impl Ctx<'_> {
    /// Runs a mutating command on one existing ticket.
    fn mutate(
        &mut self,
        ticket: &str,
        f: impl FnOnce(&View, Ulid) -> Result<Plan>,
    ) -> Result<(Value, i32)> {
        let tracker = &self.tracker;
        let mut target = None;
        let written = tracker.write(self.clock, self.actor_name.as_deref(), |rp| {
            let view = View::new(tracker, rp);
            let id = view.resolve(ticket)?;
            target = Some(id);
            f(&view, id)
        })?;
        Ok((self.report(&written, target.expect("resolved")), 0))
    }

    fn report(&self, w: &Written, ticket: Ulid) -> Value {
        let view = View::new(&self.tracker, &w.replay);
        let t = &w.replay.state.tickets[&ticket];
        json!({
            "written": w.written(),
            "event": w.primary(),
            "events": w.events,
            "ticket": view.ticket(t),
        })
    }
}

fn one(target: Ulid, op: Op) -> Plan {
    Plan {
        ops: vec![(Target::Entity(target), op)],
        blobs: Vec::new(),
        refs: Vec::new(),
    }
}

fn parse_base(s: &str) -> Result<Option<Ulid>> {
    if s.eq_ignore_ascii_case("none") || s == "null" {
        return Ok(None);
    }
    Ulid::parse_canonical(&s.to_ascii_uppercase())
        .map(Some)
        .map_err(|_| {
            Error::InvalidArgument(format!(
                "--base must be a full version id or `none`, not {s:?}"
            ))
        })
}

fn dispatch(cli: Cli, clock: &mut dyn Clock, stdin: &mut dyn Read) -> Result<(Value, i32)> {
    if let Command::Init { prefix, name } = &cli.command {
        let dir = match &cli.tracker {
            Some(d) => d.clone(),
            None => std::env::current_dir().map_err(Error::io("."))?,
        };
        let name = match name {
            Some(n) => n.clone(),
            None => std::fs::canonicalize(&dir)
                .unwrap_or_else(|_| dir.clone())
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_else(|| "tracker".into()),
        };
        let t = Tracker::init(&dir, &name, prefix, clock)?;
        let actor = t.actor_id(false, clock)?;
        return Ok((
            json!({
                "tracker": {
                    "root": t.root,
                    "id": t.config.id,
                    "name": t.config.name,
                    "prefix": t.config.prefix,
                    "statuses": t.config.statuses,
                    "kinds": t.config.kinds,
                },
                "actor": actor,
            }),
            0,
        ));
    }

    let tracker = open(cli.tracker.as_deref())?;
    let mut ctx = Ctx {
        tracker,
        clock,
        actor_name: cli.actor_name,
    };
    match cli.command {
        Command::Init { .. } => unreachable!("handled above"),
        Command::Create {
            title,
            status,
            kind,
            parent,
            tags,
        } => {
            let tracker = &ctx.tracker;
            let w = tracker.write(ctx.clock, ctx.actor_name.as_deref(), |rp: &Replay| {
                let view = View::new(tracker, rp);
                let status = status.unwrap_or_else(|| rp.state.statuses[0].clone());
                let mut ops = vec![(
                    Target::Created,
                    Op::Create(CreateData {
                        title,
                        status,
                        kind,
                    }),
                )];
                if let Some(p) = parent {
                    let p = view.resolve(&p)?;
                    ops.push((Target::Created, Op::Parent(ParentData { to: Some(p) })));
                }
                for tag in tags {
                    ops.push((Target::Created, Op::Tag(TagData { tag })));
                }
                Ok(Plan {
                    ops,
                    blobs: Vec::new(),
                    refs: Vec::new(),
                })
            })?;
            let created = w
                .events
                .iter()
                .find(|e| matches!(e.op, Op::Create(_)))
                .expect("create always changes state");
            let id = created.id;
            let view = View::new(&ctx.tracker, &w.replay);
            Ok((
                json!({
                    "written": true,
                    "event": created,
                    "events": w.events,
                    "ticket": view.ticket(&w.replay.state.tickets[&id]),
                }),
                0,
            ))
        }
        Command::Status { ticket, status } => ctx.mutate(&ticket, |_, id| {
            Ok(one(id, Op::Status(TextTo { to: status })))
        }),
        Command::Title { ticket, title } => ctx.mutate(&ticket, |_, id| {
            Ok(one(id, Op::Title(TextTo { to: title })))
        }),
        Command::Kind { ticket, kind, .. } => ctx.mutate(&ticket, |_, id| {
            Ok(one(id, Op::Kind(KindData { to: kind })))
        }),
        Command::Parent { ticket, parent, .. } => ctx.mutate(&ticket, |view, id| {
            let to = parent.map(|p| view.resolve(&p)).transpose()?;
            Ok(one(id, Op::Parent(ParentData { to })))
        }),
        Command::Relate {
            ticket,
            other,
            remove,
        } => ctx.mutate(&ticket, |view, id| {
            let to = view.resolve(&other)?;
            let d = RelateData { to };
            Ok(one(
                id,
                if remove {
                    Op::Unrelate(d)
                } else {
                    Op::Relate(d)
                },
            ))
        }),
        Command::Tag {
            ticket,
            tag,
            remove,
        } => ctx.mutate(&ticket, |_, id| {
            let d = TagData { tag };
            Ok(one(id, if remove { Op::Untag(d) } else { Op::Tag(d) }))
        }),
        Command::Branch { ticket, repo, name } => ctx.mutate(&ticket, |_, id| {
            Ok(one(id, Op::Branch(BranchData { repo, name })))
        }),
        Command::Mr { ticket, repo, url } => {
            ctx.mutate(&ticket, |_, id| Ok(one(id, Op::Mr(MrData { repo, url }))))
        }
        Command::Archive { ticket } => {
            ctx.mutate(&ticket, |_, id| Ok(one(id, Op::Archive(Empty {}))))
        }
        Command::Tombstone { ticket } => {
            ctx.mutate(&ticket, |_, id| Ok(one(id, Op::Tombstone(Empty {}))))
        }
        Command::Comment {
            ticket,
            text,
            file,
            link,
        } => {
            let text = match text {
                Some(t) => t,
                None => read_text(file.as_deref(), stdin)?,
            };
            ctx.mutate(&ticket, |_, id| {
                // Checked here as well as in `apply`, which cannot read a
                // blob's text: whether text is stored inline or as a blob
                // must not change what is accepted.
                if text.trim().is_empty() {
                    return Err(Error::Rejected(Rejection {
                        code: RejectCode::InvalidComment,
                        message: "comment text is empty".into(),
                    }));
                }
                if text.len() > INLINE_COMMENT_LIMIT {
                    let blob = blob_name(&text);
                    Ok(Plan {
                        ops: vec![(
                            Target::Entity(id),
                            Op::Comment(CommentData {
                                text: None,
                                blob: Some(blob),
                                link,
                            }),
                        )],
                        blobs: vec![text],
                        refs: Vec::new(),
                    })
                } else {
                    Ok(one(
                        id,
                        Op::Comment(CommentData {
                            text: Some(text),
                            blob: None,
                            link,
                        }),
                    ))
                }
            })
        }
        Command::Doc {
            command:
                DocCommand::Set {
                    ticket,
                    name,
                    base,
                    file,
                },
        } => {
            let base = parse_base(&base)?;
            let text = read_text(file.as_deref(), stdin)?;
            ctx.mutate(&ticket, |_, id| {
                Ok(Plan {
                    ops: vec![(
                        Target::Entity(id),
                        Op::Doc(DocData {
                            name,
                            blob: blob_name(&text),
                            base,
                        }),
                    )],
                    blobs: vec![text],
                    refs: Vec::new(),
                })
            })
        }
        Command::Doc {
            command: DocCommand::Get { ticket, name },
        } => {
            let rp = ctx.tracker.load()?;
            let view = View::new(&ctx.tracker, &rp);
            let t = &rp.state.tickets[&view.resolve(&ticket)?];
            let v = t
                .documents
                .get(&name)
                .and_then(|d| d.current_version())
                .ok_or_else(|| Error::UnknownDocument(name.clone()))?;
            let text = ctx.tracker.get_blob(&v.blob)?;
            Ok((
                json!({
                    "ticket": t.id,
                    "display": view.display(t),
                    "name": name,
                    "version": v.id,
                    "blob": v.blob,
                    "actor": v.actor,
                    "ts": v.ts,
                    "text": text,
                }),
                0,
            ))
        }
        Command::Show { ticket } => {
            let rp = ctx.tracker.load()?;
            let view = View::new(&ctx.tracker, &rp);
            let id = view.resolve(&ticket)?;
            Ok((view.ticket(&rp.state.tickets[&id]), 0))
        }
        Command::List {
            status,
            tag,
            kind,
            all,
        } => {
            let rp = ctx.tracker.load()?;
            let view = View::new(&ctx.tracker, &rp);
            let items: Vec<Value> = rp
                .state
                .tickets
                .values()
                .filter(|t| all || !(t.archived || t.tombstoned))
                .filter(|t| status.is_empty() || status.contains(&t.status))
                .filter(|t| tag.iter().all(|g| t.tags.contains(g)))
                .filter(|t| kind.is_empty() || t.kind.as_ref().is_some_and(|k| kind.contains(k)))
                .map(|t| view.summary(t))
                .collect();
            Ok((json!({ "tickets": items }), 0))
        }
        Command::Import {
            command:
                ImportCommand::AiWorkflow {
                    source,
                    exclude,
                    exclude_file,
                    repo_alias,
                    dry_run,
                },
        } => {
            let mut opts = crate::import::Options {
                source,
                dry_run,
                ..Default::default()
            };
            for id in exclude {
                let id = id.trim();
                if !id.is_empty() {
                    opts.exclude.insert(id.to_string());
                }
            }
            for path in exclude_file {
                let text = std::fs::read_to_string(&path).map_err(Error::io(&path))?;
                opts.exclude
                    .extend(crate::import::parse_exclude_file(&text)?);
            }
            for pair in repo_alias {
                let (from, to) = pair.split_once('=').ok_or_else(|| {
                    Error::InvalidArgument(format!("--repo-alias wants FROM=TO, not {pair:?}"))
                })?;
                opts.repo_aliases
                    .insert(from.trim().to_string(), to.trim().to_string());
            }
            let report = crate::import::import(&ctx.tracker, ctx.clock, &opts)?;
            Ok((report, 0))
        }
        Command::Lint => {
            let rp = ctx.tracker.load()?;
            let (report, issues) = lint(&ctx.tracker.config, &rp);
            Ok((report, if issues { 1 } else { 0 }))
        }
    }
}

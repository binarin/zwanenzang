//! Errors returned to callers. Each has a stable machine code for JSON.

use std::path::PathBuf;

use crate::state::Rejection;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("{path}: {source}")]
    Io {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error("no zwanenzang.toml found in {0} or any parent directory")]
    NotATracker(PathBuf),
    #[error("a tracker already exists at {0}")]
    AlreadyInitialized(PathBuf),
    #[error("{path}: {message}")]
    Config { path: PathBuf, message: String },
    #[error("{0}")]
    Rejected(Rejection),
    #[error("no ticket matches {0:?}")]
    UnknownTicket(String),
    #[error("{0:?} matches several tickets: {1}")]
    AmbiguousTicket(String, String),
    #[error("ticket has no document {0:?}")]
    UnknownDocument(String),
    #[error("blob {0} is missing or unreadable")]
    MissingBlob(String),
    #[error("{0}")]
    InvalidArgument(String),
}

impl Error {
    pub fn code(&self) -> &'static str {
        match self {
            Error::Io { .. } => "io",
            Error::NotATracker(_) => "not-a-tracker",
            Error::AlreadyInitialized(_) => "already-initialized",
            Error::Config { .. } => "config",
            Error::Rejected(r) => r.code.as_str(),
            Error::UnknownTicket(_) => "unknown-ticket",
            Error::AmbiguousTicket(..) => "ambiguous-ticket",
            Error::UnknownDocument(_) => "unknown-document",
            Error::MissingBlob(_) => "missing-blob",
            Error::InvalidArgument(_) => "invalid-argument",
        }
    }

    pub fn io(path: impl Into<PathBuf>) -> impl FnOnce(std::io::Error) -> Error {
        let path = path.into();
        move |source| Error::Io { path, source }
    }
}

pub type Result<T> = std::result::Result<T, Error>;

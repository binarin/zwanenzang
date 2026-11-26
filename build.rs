//! Bundles `docs/agent-hooks/` into the executable as a table of logical
//! document names, so `agent-hooks show-document` needs no files at run time.
//! A file's name is its path below that directory without `.md`; a
//! directory's `overview.md` is named after the directory itself.
//!
//! It also sets `ZWANENZANG_VERSION`, the text `--version` prints after the
//! program name: the Cargo version, then the commit and its UTC date when
//! the build is given them (the flake passes `ZWANENZANG_REV` and
//! `ZWANENZANG_DATE`), or `(unknown)` otherwise.

use std::fs;
use std::path::{Path, PathBuf};

const SOURCE: &str = "docs/agent-hooks";

fn main() {
    println!("cargo::rerun-if-changed={SOURCE}");
    println!("cargo::rustc-env=ZWANENZANG_VERSION={}", version());
    let root = Path::new(&std::env::var("CARGO_MANIFEST_DIR").unwrap()).join(SOURCE);
    let mut docs: Vec<(String, PathBuf)> = Vec::new();
    walk(&root, "", &mut docs);
    docs.sort();
    for pair in docs.windows(2) {
        assert!(
            pair[0].0 != pair[1].0,
            "{} and {} both name agent document {:?}",
            pair[0].1.display(),
            pair[1].1.display(),
            pair[0].0
        );
    }
    assert!(
        docs.iter().any(|(n, _)| n == "overview"),
        "{SOURCE}/overview.md is missing"
    );
    let mut out = String::from("pub static DOCUMENTS: &[(&str, &str)] = &[\n");
    for (name, path) in &docs {
        let path = path.to_str().expect("UTF-8 source path");
        out.push_str(&format!("    ({name:?}, include_str!({path:?})),\n"));
    }
    out.push_str("];\n");
    let dest = Path::new(&std::env::var("OUT_DIR").unwrap()).join("agent_hooks.rs");
    fs::write(dest, out).unwrap();
}

fn version() -> String {
    let mut source = Vec::new();
    for name in ["ZWANENZANG_REV", "ZWANENZANG_DATE"] {
        println!("cargo::rerun-if-env-changed={name}");
        source.extend(std::env::var(name).ok().filter(|v| !v.is_empty()));
    }
    let source = match source.as_slice() {
        [rev, date] => format!("{rev} {date}"),
        _ => "unknown".to_string(),
    };
    format!("{} ({source})", std::env::var("CARGO_PKG_VERSION").unwrap())
}

fn walk(dir: &Path, prefix: &str, docs: &mut Vec<(String, PathBuf)>) {
    let mut has_overview = false;
    for entry in fs::read_dir(dir).unwrap_or_else(|e| panic!("{}: {e}", dir.display())) {
        let entry = entry.unwrap();
        let path = entry.path();
        let file = entry.file_name().into_string().expect("UTF-8 file name");
        assert!(
            !file.contains(['/', '\\']) && !file.starts_with('.'),
            "unexpected entry {}",
            path.display()
        );
        if entry.file_type().unwrap().is_dir() {
            walk(&path, &format!("{prefix}{file}/"), docs);
            continue;
        }
        let stem = file
            .strip_suffix(".md")
            .unwrap_or_else(|| panic!("{} is not a .md file", path.display()));
        let name = if stem == "overview" {
            has_overview = true;
            match prefix.strip_suffix('/') {
                Some(dir) => dir.to_string(),
                None => "overview".to_string(),
            }
        } else {
            format!("{prefix}{stem}")
        };
        docs.push((name, path));
    }
    assert!(
        has_overview,
        "{} has no overview.md landing document",
        dir.display()
    );
}

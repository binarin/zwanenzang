//! Markdown files with a YAML frontmatter block, as the frozen ai-workflow
//! tracker writes them.
//!
//! Only the subset of YAML that tracker uses is read: top-level keys whose
//! value is a scalar, an empty or flow list of scalars (`[]`, `[a, b]`), or
//! a block of `- item` lines or `key: scalar` lines indented one level.
//! Anything else (nested blocks, block scalars, anchors, flow maps) is an
//! error rather than a guess, so an import never stores a misread value. A
//! YAML library would accept more than the importer can map anyway.

/// A frontmatter value.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Value {
    /// An empty value, `~` or `null`.
    Null,
    Str(String),
    List(Vec<String>),
    /// Entries in file order; a value may be null.
    Map(Vec<(String, Option<String>)>),
}

/// One top-level key.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Field {
    pub key: String,
    pub value: Value,
    /// The key's lines exactly as written, including its indented block.
    pub raw: String,
}

/// A file split into its frontmatter fields and its body.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Parsed {
    /// False when the file does not start with a `---` line.
    pub has_frontmatter: bool,
    pub fields: Vec<Field>,
    /// Everything after the closing `---` line, or the whole file.
    pub body: String,
}

impl Parsed {
    pub fn get(&self, key: &str) -> Option<&Field> {
        self.fields.iter().find(|f| f.key == key)
    }
}

/// Splits `text` into frontmatter and body and parses the frontmatter.
pub fn parse(text: &str) -> Result<Parsed, String> {
    let text = text.strip_prefix('\u{feff}').unwrap_or(text);
    let mut lines = text.split_inclusive('\n');
    let first = lines.next().unwrap_or("");
    if first.trim_end_matches(['\n', '\r']) != "---" {
        return Ok(Parsed {
            has_frontmatter: false,
            fields: Vec::new(),
            body: text.to_string(),
        });
    }
    let mut header = Vec::new();
    let mut closed = false;
    for line in lines.by_ref() {
        if line.trim_end_matches(['\n', '\r']) == "---" {
            closed = true;
            break;
        }
        header.push(line);
    }
    if !closed {
        return Err("frontmatter is not closed by a `---` line".into());
    }
    let body: String = lines.collect();
    Ok(Parsed {
        has_frontmatter: true,
        fields: parse_fields(&header)?,
        body,
    })
}

fn is_blank_or_comment(line: &str) -> bool {
    let t = line.trim();
    t.is_empty() || t.starts_with('#')
}

fn parse_fields(lines: &[&str]) -> Result<Vec<Field>, String> {
    let mut fields: Vec<Field> = Vec::new();
    let mut i = 0;
    while i < lines.len() {
        let line = lines[i].trim_end_matches(['\n', '\r']);
        let n = i + 1;
        i += 1;
        if is_blank_or_comment(line) {
            continue;
        }
        if line.starts_with([' ', '\t']) {
            return Err(format!("line {n}: unexpected indentation"));
        }
        let (key, rest) =
            split_key(line).ok_or_else(|| format!("line {n}: expected `key: value`"))?;
        if fields.iter().any(|f| f.key == key) {
            return Err(format!("line {n}: duplicate key {key:?}"));
        }
        let mut raw = String::from(lines[n - 1]);
        let value = if rest.is_empty() {
            // A block, or nothing: the indented lines that follow.
            let start = i;
            while i < lines.len() {
                let l = lines[i].trim_end_matches(['\n', '\r']);
                if l.starts_with([' ', '\t']) || l.trim().is_empty() {
                    i += 1;
                } else {
                    break;
                }
            }
            // Trailing blank lines belong to no key.
            let mut end = i;
            while end > start && lines[end - 1].trim().is_empty() {
                end -= 1;
            }
            for l in &lines[start..end] {
                raw.push_str(l);
            }
            parse_block(&lines[start..end], start + 1).map_err(|e| format!("key {key:?}: {e}"))?
        } else if rest.starts_with('[') {
            Value::List(parse_flow_list(rest).map_err(|e| format!("line {n}: {e}"))?)
        } else {
            match parse_scalar(rest).map_err(|e| format!("line {n}: {e}"))? {
                Some(s) => Value::Str(s),
                None => Value::Null,
            }
        };
        if !raw.ends_with('\n') {
            raw.push('\n');
        }
        fields.push(Field {
            key: key.to_string(),
            value,
            raw,
        });
    }
    Ok(fields)
}

/// `key: rest` with the rest trimmed; the key is everything before the
/// first `: ` (or a final `:`).
fn split_key(line: &str) -> Option<(&str, &str)> {
    let (key, rest) = match line.find(": ") {
        Some(p) => (&line[..p], &line[p + 2..]),
        None => (line.strip_suffix(':')?, ""),
    };
    let key = key.trim();
    if key.is_empty() || key.starts_with(['-', '[', '{', '"', '\'']) {
        return None;
    }
    Some((key, rest.trim()))
}

fn parse_block(lines: &[&str], first_line: usize) -> Result<Value, String> {
    let content: Vec<(usize, &str)> = lines
        .iter()
        .enumerate()
        .map(|(k, l)| (first_line + k, l.trim_end_matches(['\n', '\r'])))
        .filter(|(_, l)| !is_blank_or_comment(l))
        .collect();
    let Some(&(_, first)) = content.first() else {
        return Ok(Value::Null);
    };
    let indent = first.len() - first.trim_start().len();
    let is_item = |l: &str| l.trim_start() == "-" || l.trim_start().starts_with("- ");
    let list = is_item(first);
    let mut items = Vec::new();
    let mut entries: Vec<(String, Option<String>)> = Vec::new();
    for (n, l) in content {
        let this = l.len() - l.trim_start().len();
        if this != indent || l[..this].contains('\t') {
            return Err(format!(
                "line {n}: nested or uneven indentation is not supported"
            ));
        }
        if list {
            if !is_item(l) {
                return Err(format!("line {n}: expected a `- item` line"));
            }
            let item = l.trim_start()[1..].trim();
            match parse_scalar(item).map_err(|e| format!("line {n}: {e}"))? {
                Some(s) => items.push(s),
                None => return Err(format!("line {n}: empty list item")),
            }
        } else {
            let (k, v) = split_key(l.trim_start())
                .ok_or_else(|| format!("line {n}: expected `key: value`"))?;
            if v.starts_with('[') {
                return Err(format!("line {n}: lists inside a map are not supported"));
            }
            if entries.iter().any(|(e, _)| e == k) {
                return Err(format!("line {n}: duplicate key {k:?}"));
            }
            entries.push((
                k.to_string(),
                parse_scalar(v).map_err(|e| format!("line {n}: {e}"))?,
            ));
        }
    }
    Ok(if list {
        Value::List(items)
    } else {
        Value::Map(entries)
    })
}

fn parse_flow_list(text: &str) -> Result<Vec<String>, String> {
    let (inner, after) = text[1..]
        .split_once(']')
        .ok_or_else(|| "unclosed flow list".to_string())?;
    let after = after.trim();
    if !(after.is_empty() || after.starts_with('#')) {
        return Err("text after a flow list".into());
    }
    if inner.contains(['[', '{', '"', '\'']) {
        return Err("only plain items are supported in a flow list".into());
    }
    if inner.trim().is_empty() {
        return Ok(Vec::new());
    }
    inner
        .split(',')
        .map(|item| {
            let item = item.trim();
            if item.is_empty() {
                Err("empty flow list item".to_string())
            } else {
                Ok(item.to_string())
            }
        })
        .collect()
}

/// A plain, single-quoted or double-quoted scalar; `None` for null.
fn parse_scalar(text: &str) -> Result<Option<String>, String> {
    let t = text.trim();
    if let Some(rest) = t.strip_prefix('"') {
        let mut out = String::new();
        let mut chars = rest.chars();
        loop {
            match chars.next() {
                None => return Err("unclosed double quote".into()),
                Some('"') => break,
                Some('\\') => match chars.next() {
                    Some('"') => out.push('"'),
                    Some('\\') => out.push('\\'),
                    Some('/') => out.push('/'),
                    Some('n') => out.push('\n'),
                    Some('t') => out.push('\t'),
                    other => return Err(format!("unsupported escape {other:?}")),
                },
                Some(c) => out.push(c),
            }
        }
        return trailing(chars.as_str()).map(|()| Some(out));
    }
    if let Some(rest) = t.strip_prefix('\'') {
        let mut out = String::new();
        let mut chars = rest.chars().peekable();
        loop {
            match chars.next() {
                None => return Err("unclosed single quote".into()),
                Some('\'') if chars.peek() == Some(&'\'') => {
                    chars.next();
                    out.push('\'');
                }
                Some('\'') => break,
                Some(c) => out.push(c),
            }
        }
        let rest: String = chars.collect();
        return trailing(&rest).map(|()| Some(out));
    }
    // A comment starts at ` #`; a `#` inside a word is text.
    let plain = match t.find(" #") {
        Some(p) => t[..p].trim_end(),
        None if t.starts_with('#') => "",
        None => t,
    };
    if plain.starts_with(['|', '>', '&', '*', '!', '{', '[', '@', '`']) {
        return Err(format!("unsupported YAML value {plain:?}"));
    }
    Ok(match plain {
        "" | "~" | "null" | "Null" | "NULL" => None,
        s => Some(s.to_string()),
    })
}

fn trailing(rest: &str) -> Result<(), String> {
    let r = rest.trim();
    if r.is_empty() || r.starts_with('#') {
        Ok(())
    } else {
        Err(format!("text after a quoted value: {r:?}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fields(text: &str) -> Vec<(String, Value)> {
        parse(text)
            .unwrap()
            .fields
            .into_iter()
            .map(|f| (f.key, f.value))
            .collect()
    }

    fn s(v: &str) -> Value {
        Value::Str(v.into())
    }

    #[test]
    fn every_shape_the_tracker_uses() {
        let text = "---\nstatus: draft\noriginal-ticket: AB-0001\nrelated:\n  - AB-0002\n  - AB-0003\nbranches:\n  app: ab-0004-x\nhandoff:\n  stage: ready\n  outcome:\nmerge-requests: []\nother: [a, b]\n---\n\n# Title\n";
        assert_eq!(
            fields(text),
            vec![
                ("status".into(), s("draft")),
                ("original-ticket".into(), s("AB-0001")),
                (
                    "related".into(),
                    Value::List(vec!["AB-0002".into(), "AB-0003".into()])
                ),
                (
                    "branches".into(),
                    Value::Map(vec![("app".into(), Some("ab-0004-x".into()))])
                ),
                (
                    "handoff".into(),
                    Value::Map(vec![
                        ("stage".into(), Some("ready".into())),
                        ("outcome".into(), None)
                    ])
                ),
                ("merge-requests".into(), Value::List(vec![])),
                ("other".into(), Value::List(vec!["a".into(), "b".into()])),
            ]
        );
        let p = parse(text).unwrap();
        assert_eq!(p.body, "\n# Title\n");
        assert_eq!(
            p.get("handoff").unwrap().raw,
            "handoff:\n  stage: ready\n  outcome:\n"
        );
    }

    #[test]
    fn scalars() {
        assert_eq!(parse_scalar("\"draft\"").unwrap(), Some("draft".into()));
        assert_eq!(parse_scalar("'it''s'").unwrap(), Some("it's".into()));
        assert_eq!(parse_scalar("a#b # note").unwrap(), Some("a#b".into()));
        assert_eq!(parse_scalar("~").unwrap(), None);
        assert_eq!(parse_scalar("").unwrap(), None);
        assert_eq!(
            parse_scalar("\"é \\\"q\\\"\"").unwrap(),
            Some("é \"q\"".into())
        );
        assert!(parse_scalar("|").is_err());
        assert!(parse_scalar("\"open").is_err());
        assert!(parse_scalar("\"a\" b").is_err());
    }

    #[test]
    fn no_frontmatter_is_all_body() {
        let p = parse("# Title\n\ntext\n").unwrap();
        assert!(!p.has_frontmatter);
        assert!(p.fields.is_empty());
        assert_eq!(p.body, "# Title\n\ntext\n");
    }

    #[test]
    fn empty_key_is_null_and_comments_are_skipped() {
        assert_eq!(
            fields("---\n# a comment\nrelated:\n\nstatus: done\n---\n"),
            vec![
                ("related".into(), Value::Null),
                ("status".into(), s("done"))
            ]
        );
    }

    #[test]
    fn unsupported_or_broken_yaml_is_an_error() {
        for bad in [
            "---\nstatus: draft\n",
            "---\nstatus: draft\nstatus: done\n---\n",
            "---\nrelated:\n  - a\n    - b\n---\n",
            "---\nrelated:\n  - a\n  b: c\n---\n",
            "---\nhandoff:\n  stage:\n    deep: x\n---\n",
            "---\nbody: |\n  text\n---\n",
            "---\nx: {a: b}\n---\n",
            "---\nx: [a, [b]]\n---\n",
            "---\n  indented: x\n---\n",
            "---\njust text\n---\n",
            "---\nrelated:\n  -\n---\n",
        ] {
            assert!(parse(bad).is_err(), "{bad:?} should not parse");
        }
    }

    #[test]
    fn crlf_lines() {
        assert_eq!(
            fields("---\r\nstatus: done\r\nrelated:\r\n  - A-0001\r\n---\r\nbody\r\n"),
            vec![
                ("status".into(), s("done")),
                ("related".into(), Value::List(vec!["A-0001".into()]))
            ]
        );
    }
}

//! A small Org to HTML renderer for tracker prose, used by `render`.
//!
//! It knows the subset tracker prose uses: headings, paragraphs, plain,
//! ordered and description lists with checkboxes, emphasis, `~code~` and
//! `=verbatim=`, links, src, example and quote blocks, fixed-width lines,
//! horizontal rules and simple tables. Anything else that has a recognisable
//! shape (other blocks, drawers, keyword lines) is shown preformatted, so
//! nothing the author wrote disappears. Comment lines are dropped, as Org
//! export drops them. All text is escaped; the output is safe to insert as
//! HTML.

/// How links that point inside the tracker become hrefs.
pub trait LinkResolver {
    /// The href for a ticket reference such as `ZZ-12`, when it names a
    /// ticket in the output.
    fn ticket(&self, reference: &str) -> Option<String>;
    /// The href for a link to a file, such as `docs/plan.org`, when that
    /// file is part of the output.
    fn file(&self, path: &str) -> Option<String>;
}

/// Resolves nothing: every ticket reference stays text.
pub struct NoLinks;

impl LinkResolver for NoLinks {
    fn ticket(&self, _: &str) -> Option<String> {
        None
    }
    fn file(&self, _: &str) -> Option<String> {
        None
    }
}

/// Renders Org `text` as an HTML fragment.
pub fn to_html(text: &str, links: &dyn LinkResolver) -> String {
    let normalized = text.replace("\r\n", "\n");
    let lines: Vec<&str> = normalized.split('\n').collect();
    let mut out = String::new();
    blocks(&lines, links, &mut out);
    out
}

pub fn escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    escape_into(s, &mut out);
    out
}

fn escape_into(s: &str, out: &mut String) {
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            c => out.push(c),
        }
    }
}

fn indent_of(line: &str) -> usize {
    line.len() - line.trim_start_matches([' ', '\t']).len()
}

fn is_blank(line: &str) -> bool {
    line.trim().is_empty()
}

/// `(level, text)` of a heading line.
fn heading(line: &str) -> Option<(usize, &str)> {
    let stars = line.len() - line.trim_start_matches('*').len();
    if stars == 0 {
        return None;
    }
    let rest = &line[stars..];
    if rest.is_empty() {
        return Some((stars, ""));
    }
    rest.strip_prefix([' ', '\t']).map(|t| (stars, t.trim()))
}

/// The block name of a `#+begin_NAME` line, lowercased, and its parameters.
fn begin_block(line: &str) -> Option<(String, &str)> {
    let t = line.trim_start();
    let head = t.get(..8)?;
    if !head.eq_ignore_ascii_case("#+begin_") {
        return None;
    }
    let rest = &t[8..];
    let end = rest.find(char::is_whitespace).unwrap_or(rest.len());
    let name = &rest[..end];
    if name.is_empty() {
        return None;
    }
    Some((name.to_ascii_lowercase(), rest[end..].trim()))
}

fn is_end_block(line: &str, name: &str) -> bool {
    // Checked slices: a line of the block body may have a multi-byte
    // character at any byte offset.
    let t = line.trim();
    t.get(..6).is_some_and(|h| h.eq_ignore_ascii_case("#+end_"))
        && t.get(6..).is_some_and(|n| n.eq_ignore_ascii_case(name))
}

fn is_keyword_line(line: &str) -> bool {
    let t = line.trim_start();
    t.starts_with("#+") && begin_block(line).is_none()
}

fn is_comment_line(line: &str) -> bool {
    let t = line.trim_start();
    t == "#" || t.starts_with("# ")
}

fn is_drawer_start(line: &str) -> bool {
    let t = line.trim();
    t.len() > 2
        && t.starts_with(':')
        && t.ends_with(':')
        && t[1..t.len() - 1]
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        && !t.eq_ignore_ascii_case(":end:")
}

fn fixed_width(line: &str) -> Option<&str> {
    let t = line.trim_start();
    if t == ":" {
        Some("")
    } else {
        t.strip_prefix(": ")
    }
}

fn is_table_line(line: &str) -> bool {
    line.trim_start().starts_with('|')
}

fn is_rule(line: &str) -> bool {
    let t = line.trim();
    t.len() >= 5 && t.bytes().all(|b| b == b'-')
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum ListKind {
    Unordered,
    Ordered,
}

struct Bullet<'a> {
    indent: usize,
    kind: ListKind,
    /// Where the item text starts, in bytes from the line start.
    content_col: usize,
    text: &'a str,
}

fn bullet(line: &str) -> Option<Bullet<'_>> {
    let indent = indent_of(line);
    let rest = &line[indent..];
    let (kind, width) = if rest.starts_with(['-', '+']) || (indent > 0 && rest.starts_with('*')) {
        (ListKind::Unordered, 1)
    } else {
        let digits = rest.len() - rest.trim_start_matches(|c: char| c.is_ascii_digit()).len();
        if digits == 0 || !rest[digits..].starts_with(['.', ')']) {
            return None;
        }
        (ListKind::Ordered, digits + 1)
    };
    let after = &rest[width..];
    if !after.is_empty() && !after.starts_with([' ', '\t']) {
        return None;
    }
    let text = after.trim_start_matches([' ', '\t']);
    Some(Bullet {
        indent,
        kind,
        content_col: line.len() - text.len(),
        text: text.trim_end(),
    })
}

/// Whether `line` starts a block other than a paragraph, so a paragraph
/// ends before it.
fn starts_block(line: &str) -> bool {
    heading(line).is_some()
        || begin_block(line).is_some()
        || is_keyword_line(line)
        || is_comment_line(line)
        || is_table_line(line)
        || is_rule(line)
        || fixed_width(line).is_some()
        || is_drawer_start(line)
        || bullet(line).is_some()
}

fn pre(class: &str, lines: &[&str], out: &mut String) {
    out.push_str(&format!("<pre class=\"{class}\">"));
    escape_into(&lines.join("\n"), out);
    out.push_str("</pre>\n");
}

/// Removes the indentation common to all non-blank lines, and the comma
/// that protects a leading `*` or `#+` inside a block.
fn block_body(lines: &[&str]) -> Vec<String> {
    let common = lines
        .iter()
        .filter(|l| !is_blank(l))
        .map(|l| indent_of(l))
        .min()
        .unwrap_or(0);
    lines
        .iter()
        .map(|l| {
            let l = if is_blank(l) { "" } else { &l[common..] };
            let unescaped = l.strip_prefix(',').filter(|r| r.starts_with(['*', '#']));
            unescaped.unwrap_or(l).to_string()
        })
        .collect()
}

fn blocks(lines: &[&str], links: &dyn LinkResolver, out: &mut String) {
    let mut i = 0;
    while i < lines.len() {
        let line = lines[i];
        if is_blank(line) {
            i += 1;
            continue;
        }
        if let Some((level, text)) = heading(line) {
            let h = (level + 2).min(6);
            out.push_str(&format!("<h{h}>"));
            inline(text, links, out);
            out.push_str(&format!("</h{h}>\n"));
            i += 1;
            continue;
        }
        if let Some((name, params)) = begin_block(line) {
            let Some(len) = lines[i + 1..].iter().position(|l| is_end_block(l, &name)) else {
                // An unterminated block is not a block; show the line as it is.
                pre("org", &lines[i..=i], out);
                i += 1;
                continue;
            };
            let inner = &lines[i + 1..i + 1 + len];
            match name.as_str() {
                "src" => {
                    let lang = params.split_whitespace().next().unwrap_or("");
                    out.push_str("<pre class=\"src\"");
                    if !lang.is_empty() {
                        out.push_str(" data-lang=\"");
                        escape_into(lang, out);
                        out.push('"');
                    }
                    out.push_str("><code>");
                    escape_into(&block_body(inner).join("\n"), out);
                    out.push_str("</code></pre>\n");
                }
                "example" => {
                    out.push_str("<pre class=\"example\">");
                    escape_into(&block_body(inner).join("\n"), out);
                    out.push_str("</pre>\n");
                }
                "quote" => {
                    out.push_str("<blockquote>\n");
                    blocks(inner, links, out);
                    out.push_str("</blockquote>\n");
                }
                _ => pre("org", &lines[i..i + len + 2], out),
            }
            i += len + 2;
            continue;
        }
        if is_comment_line(line) {
            i += 1;
            continue;
        }
        if is_keyword_line(line) {
            let n = lines[i..].iter().take_while(|l| is_keyword_line(l)).count();
            pre("org", &lines[i..i + n], out);
            i += n;
            continue;
        }
        if is_drawer_start(line)
            && let Some(len) = lines[i + 1..]
                .iter()
                .position(|l| l.trim().eq_ignore_ascii_case(":end:"))
        {
            pre("org", &lines[i..i + len + 2], out);
            i += len + 2;
            continue;
        }
        if fixed_width(line).is_some() {
            let body: Vec<&str> = lines[i..].iter().map_while(|l| fixed_width(l)).collect();
            out.push_str("<pre class=\"fixed\">");
            escape_into(&body.join("\n"), out);
            out.push_str("</pre>\n");
            i += body.len();
            continue;
        }
        if is_table_line(line) {
            let n = lines[i..].iter().take_while(|l| is_table_line(l)).count();
            table(&lines[i..i + n], links, out);
            i += n;
            continue;
        }
        if is_rule(line) {
            out.push_str("<hr>\n");
            i += 1;
            continue;
        }
        if let Some(b) = bullet(line) {
            i = list(lines, i, b.indent, b.kind, links, out);
            continue;
        }
        // A paragraph: up to a blank line or the start of another block.
        let mut n = 1;
        while i + n < lines.len() && !is_blank(lines[i + n]) && !starts_block(lines[i + n]) {
            n += 1;
        }
        let text: Vec<&str> = lines[i..i + n].iter().map(|l| l.trim()).collect();
        out.push_str("<p>");
        inline(&text.join("\n"), links, out);
        out.push_str("</p>\n");
        i += n;
    }
}

/// Renders the list whose first item is at `start`; returns the index of
/// the first line after it.
fn list(
    lines: &[&str],
    start: usize,
    indent: usize,
    kind: ListKind,
    links: &dyn LinkResolver,
    out: &mut String,
) -> usize {
    let description = kind == ListKind::Unordered
        && bullet(lines[start]).is_some_and(|b| b.text.contains(" :: ") || b.text.ends_with(" ::"));
    let (open, close) = match (description, kind) {
        (true, _) => ("<dl>\n", "</dl>\n"),
        (false, ListKind::Ordered) => ("<ol>\n", "</ol>\n"),
        (false, ListKind::Unordered) => ("<ul>\n", "</ul>\n"),
    };
    out.push_str(open);
    let mut i = start;
    while i < lines.len() {
        let Some(b) = bullet(lines[i]).filter(|b| b.indent == indent && b.kind == kind) else {
            break;
        };
        // The item continues over lines indented deeper than its bullet;
        // a blank line followed by anything else ends it.
        let mut body: Vec<String> = Vec::new();
        let mut j = i + 1;
        while j < lines.len() {
            let l = lines[j];
            if is_blank(l) {
                let next = lines[j + 1..].iter().find(|l| !is_blank(l));
                if next.is_none_or(|n| indent_of(n) <= indent) {
                    break;
                }
                body.push(String::new());
            } else if indent_of(l) <= indent {
                break;
            } else {
                body.push(l[indent_of(l).min(b.content_col)..].to_string());
            }
            j += 1;
        }
        let (mut first, checkbox) = checkbox(b.text);
        if description {
            let (term, rest) = match first.split_once(" :: ") {
                Some((t, r)) => (t, r),
                None => (first.strip_suffix(" ::").unwrap_or(first), ""),
            };
            out.push_str("<dt>");
            inline(term.trim(), links, out);
            out.push_str("</dt><dd>");
            first = rest;
        } else {
            out.push_str("<li>");
        }
        if let Some(mark) = checkbox {
            out.push_str(mark);
        }
        let mut item: Vec<&str> = vec![first];
        item.extend(body.iter().map(String::as_str));
        let mut inner = String::new();
        blocks(&item, links, &mut inner);
        // An item whose only paragraph is its first needs no paragraph
        // markup.
        match inner
            .strip_prefix("<p>")
            .and_then(|r| r.split_once("</p>\n"))
        {
            Some((first, "")) => out.push_str(first),
            Some((first, rest)) if !rest.contains("<p>") => {
                out.push_str(first);
                out.push('\n');
                out.push_str(rest);
            }
            _ => out.push_str(&inner),
        }
        out.push_str(if description { "</dd>\n" } else { "</li>\n" });
        i = j;
        // Blank lines between items of one list do not end it.
        while i < lines.len() && is_blank(lines[i]) {
            match lines[i + 1..].iter().find(|l| !is_blank(l)) {
                Some(n) if bullet(n).is_some_and(|nb| nb.indent == indent && nb.kind == kind) => {
                    i += 1
                }
                _ => break,
            }
        }
    }
    out.push_str(close);
    i
}

fn checkbox(text: &str) -> (&str, Option<&'static str>) {
    for (mark, html) in [
        ("[ ]", "<span class=\"checkbox\">\u{2610}</span> "),
        ("[X]", "<span class=\"checkbox done\">\u{2611}</span> "),
        ("[x]", "<span class=\"checkbox done\">\u{2611}</span> "),
        ("[-]", "<span class=\"checkbox partial\">\u{25A3}</span> "),
    ] {
        if let Some(rest) = text.strip_prefix(mark)
            && (rest.is_empty() || rest.starts_with(' '))
        {
            return (rest.trim_start(), Some(html));
        }
    }
    (text, None)
}

fn table(lines: &[&str], links: &dyn LinkResolver, out: &mut String) {
    let is_sep = |l: &str| l.trim_start().starts_with("|-");
    let rows: Vec<Option<Vec<&str>>> = lines
        .iter()
        .map(|l| {
            if is_sep(l) {
                return None;
            }
            let t = l.trim();
            let t = t.strip_prefix('|').unwrap_or(t);
            let t = t.strip_suffix('|').unwrap_or(t);
            Some(t.split('|').map(str::trim).collect())
        })
        .collect();
    // Rows above the first separator are the header, when data follows it.
    let header_len = rows
        .iter()
        .position(Option::is_none)
        .filter(|&p| p > 0 && rows[p..].iter().any(Option::is_some));
    out.push_str("<table>\n");
    let row_html = |cells: &[&str], tag: &str, out: &mut String| {
        out.push_str("<tr>");
        for c in cells {
            out.push_str(&format!("<{tag}>"));
            inline(c, links, out);
            out.push_str(&format!("</{tag}>"));
        }
        out.push_str("</tr>\n");
    };
    let body_rows = match header_len {
        Some(p) => {
            out.push_str("<thead>\n");
            for cells in rows[..p].iter().flatten() {
                row_html(cells, "th", out);
            }
            out.push_str("</thead>\n");
            &rows[p..]
        }
        None => &rows[..],
    };
    out.push_str("<tbody>\n");
    for cells in body_rows.iter().flatten() {
        row_html(cells, "td", out);
    }
    out.push_str("</tbody>\n</table>\n");
}

const EMPHASIS: &[(char, &str)] = &[
    ('*', "strong"),
    ('/', "em"),
    ('_', "u"),
    ('+', "del"),
    ('~', "code"),
    ('=', "code"),
];

fn pre_emphasis_ok(prev: Option<char>) -> bool {
    prev.is_none_or(|c| c.is_whitespace() || "-({'\"".contains(c))
}

fn post_emphasis_ok(next: Option<char>) -> bool {
    next.is_none_or(|c| c.is_whitespace() || "-.,:!?;'\")}[\\".contains(c))
}

/// The byte offset of the closing `marker` of an emphasis opening at
/// `open` in `s`.
fn emphasis_end(s: &str, open: usize, marker: char) -> Option<usize> {
    let body_start = open + marker.len_utf8();
    let first = s[body_start..].chars().next()?;
    if first.is_whitespace() {
        return None;
    }
    let mut prev = first;
    for (off, c) in s[body_start + first.len_utf8()..].char_indices() {
        let at = body_start + first.len_utf8() + off;
        if c == marker && !prev.is_whitespace() && post_emphasis_ok(s[at + 1..].chars().next()) {
            return Some(at);
        }
        prev = c;
    }
    None
}

fn safe_url(target: &str) -> bool {
    let lower = target.to_ascii_lowercase();
    ["http://", "https://", "mailto:"]
        .iter()
        .any(|p| lower.starts_with(p))
}

fn link(target: &str, desc: Option<&str>, links: &dyn LinkResolver, out: &mut String) {
    let label = desc.unwrap_or(target);
    let href = if safe_url(target) {
        Some(target.to_string())
    } else if let Some(r) = links.ticket(target) {
        Some(r)
    } else {
        let path = target.strip_prefix("file:").unwrap_or(target);
        links.file(path.strip_prefix("./").unwrap_or(path))
    };
    match href {
        Some(href) => {
            out.push_str("<a href=\"");
            escape_into(&href, out);
            out.push_str("\">");
            escape_into(label, out);
            out.push_str("</a>");
        }
        None => {
            out.push_str("<span class=\"link\" title=\"");
            escape_into(target, out);
            out.push_str("\">");
            escape_into(label, out);
            out.push_str("</span>");
        }
    }
}

/// The length of a bare URL starting at the beginning of `s`.
fn bare_url_len(s: &str) -> Option<usize> {
    let lower = s.get(..8).unwrap_or(s).to_ascii_lowercase();
    if !(lower.starts_with("http://") || lower.starts_with("https://")) {
        return None;
    }
    let end = s
        .find(|c: char| c.is_whitespace() || "<>\"".contains(c))
        .unwrap_or(s.len());
    let url = s[..end].trim_end_matches(['.', ',', ';', ':', '!', '?', ')', '\'']);
    (url.len() > "https://".len() - 1).then_some(url.len())
}

/// The length of a ticket reference such as `ZZ-12` at the start of `s`.
fn ticket_ref_len(s: &str) -> Option<usize> {
    let b = s.as_bytes();
    if !b.first()?.is_ascii_uppercase() {
        return None;
    }
    let mut i = 1;
    while i < b.len() && (b[i].is_ascii_uppercase() || b[i].is_ascii_digit()) {
        i += 1;
    }
    if b.get(i) != Some(&b'-') {
        return None;
    }
    let digits = b[i + 1..].iter().take_while(|c| c.is_ascii_digit()).count();
    if digits == 0 {
        return None;
    }
    let end = i + 1 + digits;
    if b.get(end).is_some_and(|c| c.is_ascii_alphanumeric()) {
        return None;
    }
    Some(end)
}

fn inline(s: &str, links: &dyn LinkResolver, out: &mut String) {
    let mut i = 0;
    let mut prev: Option<char> = None;
    while i < s.len() {
        let rest = &s[i..];
        let c = rest.chars().next().expect("not at end");
        if rest.starts_with("[[")
            && let Some(close) = rest.find("]]")
        {
            let inner = &rest[2..close];
            let (target, desc) = match inner.split_once("][") {
                Some((t, d)) => (t, Some(d)),
                None => (inner, None),
            };
            link(target, desc, links, out);
            i += close + 2;
            prev = Some(']');
            continue;
        }
        let boundary = prev.is_none_or(|p| !(p.is_alphanumeric() || p == '-' || p == '_'));
        if boundary && let Some(n) = bare_url_len(rest) {
            link(&rest[..n], None, links, out);
            i += n;
            prev = rest[..n].chars().last();
            continue;
        }
        if boundary
            && let Some(n) = ticket_ref_len(rest)
            && let Some(href) = links.ticket(&rest[..n])
        {
            out.push_str("<a class=\"ticket-ref\" href=\"");
            escape_into(&href, out);
            out.push_str("\">");
            escape_into(&rest[..n], out);
            out.push_str("</a>");
            i += n;
            prev = Some('0');
            continue;
        }
        if let Some(&(marker, tag)) = EMPHASIS.iter().find(|(m, _)| *m == c)
            && pre_emphasis_ok(prev)
            && let Some(end) = emphasis_end(s, i, marker)
        {
            let body = &s[i + 1..end];
            out.push_str(&format!("<{tag}>"));
            if matches!(marker, '~' | '=') {
                escape_into(body, out);
            } else {
                inline(body, links, out);
            }
            out.push_str(&format!("</{tag}>"));
            i = end + 1;
            prev = Some(marker);
            continue;
        }
        if let Some(after) = rest.strip_prefix("\\\\")
            && after
                .trim_start_matches([' ', '\t'])
                .chars()
                .next()
                .is_none_or(|c| c == '\n')
        {
            out.push_str("<br>");
            i += 2;
            prev = Some('\\');
            continue;
        }
        escape_into(&rest[..c.len_utf8()], out);
        i += c.len_utf8();
        prev = Some(c);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn html(s: &str) -> String {
        to_html(s, &NoLinks)
    }

    struct Some12;
    impl LinkResolver for Some12 {
        fn ticket(&self, r: &str) -> Option<String> {
            (r == "ZZ-12").then(|| "#ZZ-12".into())
        }
        fn file(&self, p: &str) -> Option<String> {
            (p == "docs/plan.org").then(|| "files/plan.org".into())
        }
    }

    #[test]
    fn headings_and_paragraphs() {
        assert_eq!(
            html("* Top\nfirst line\nsecond line\n\n** Sub"),
            "<h3>Top</h3>\n<p>first line\nsecond line</p>\n<h4>Sub</h4>\n"
        );
        assert_eq!(html("***** deep"), "<h6>deep</h6>\n");
    }

    #[test]
    fn escapes_everything() {
        assert_eq!(
            html("<script>alert('x') & \"y\"</script>"),
            "<p>&lt;script&gt;alert(&#39;x&#39;) &amp; &quot;y&quot;&lt;/script&gt;</p>\n"
        );
    }

    #[test]
    fn emphasis_and_code() {
        assert_eq!(
            html("*bold* /it/ _u_ +del+ ~a<b~ =v *not*="),
            "<p><strong>bold</strong> <em>it</em> <u>u</u> <del>del</del> \
             <code>a&lt;b</code> <code>v *not*</code></p>\n"
        );
        // Markers inside words or next to spaces are plain text.
        assert_eq!(html("a*b*c 2 * 3 * 4"), "<p>a*b*c 2 * 3 * 4</p>\n");
        assert_eq!(
            html("(*nested /it/*)."),
            "<p>(<strong>nested <em>it</em></strong>).</p>\n"
        );
    }

    #[test]
    fn links() {
        assert_eq!(
            html("[[https://example.org/a?b=1&c][the site]] and https://x.example/p."),
            "<p><a href=\"https://example.org/a?b=1&amp;c\">the site</a> and \
             <a href=\"https://x.example/p\">https://x.example/p</a>.</p>\n"
        );
        // Unsafe or unresolved targets never become hrefs.
        assert_eq!(
            html("[[javascript:alert(1)][x]]"),
            "<p><span class=\"link\" title=\"javascript:alert(1)\">x</span></p>\n"
        );
        assert_eq!(
            to_html(
                "see ZZ-12, XZZ-12, ZZ-13 and [[file:docs/plan.org][plan]]",
                &Some12
            ),
            "<p>see <a class=\"ticket-ref\" href=\"#ZZ-12\">ZZ-12</a>, XZZ-12, ZZ-13 and \
             <a href=\"files/plan.org\">plan</a></p>\n"
        );
    }

    #[test]
    fn plain_and_ordered_lists() {
        assert_eq!(
            html("- one\n  continued\n- two\n  + nested\n\n- three\n\nafter"),
            "<ul>\n<li>one\ncontinued</li>\n<li>two\n<ul>\n<li>nested</li>\n</ul>\n</li>\n\
             <li>three</li>\n</ul>\n<p>after</p>\n"
        );
        assert_eq!(html("1. a\n2) b"), "<ol>\n<li>a</li>\n<li>b</li>\n</ol>\n");
        assert_eq!(html("a line\\\\\nnext"), "<p>a line<br>\nnext</p>\n");
        assert_eq!(
            html("- [ ] todo\n- [X] done"),
            "<ul>\n<li><span class=\"checkbox\">\u{2610}</span> todo</li>\n\
             <li><span class=\"checkbox done\">\u{2611}</span> done</li>\n</ul>\n"
        );
    }

    #[test]
    fn description_lists() {
        assert_eq!(
            html("- term :: meaning\n- other :: more"),
            "<dl>\n<dt>term</dt><dd>meaning</dd>\n<dt>other</dt><dd>more</dd>\n</dl>\n"
        );
    }

    #[test]
    fn blocks_of_code_examples_and_quotes() {
        assert_eq!(
            html("#+begin_src rust\n  fn main() {}\n  ,* not a heading\n#+end_src"),
            "<pre class=\"src\" data-lang=\"rust\"><code>fn main() {}\n* not a heading</code></pre>\n"
        );
        assert_eq!(
            html("#+BEGIN_EXAMPLE\n<x>\n#+END_EXAMPLE"),
            "<pre class=\"example\">&lt;x&gt;</pre>\n"
        );
        assert_eq!(
            html("#+begin_quote\nwise *words*\n#+end_quote"),
            "<blockquote>\n<p>wise <strong>words</strong></p>\n</blockquote>\n"
        );
        assert_eq!(
            html(": fixed\n:\n: width"),
            "<pre class=\"fixed\">fixed\n\nwidth</pre>\n"
        );
        assert_eq!(html("-----"), "<hr>\n");
    }

    #[test]
    fn unicode_never_splits_a_character() {
        // Body lines as long in bytes as `#+end_NAME`, with a multi-byte
        // character across byte 6, once crashed the end-of-block check.
        for name in ["src", "example", "quote", "verse"] {
            let body = "a\u{1F642}\u{e9}ab";
            let closed = to_html(&format!("#+begin_{name}\n{body}\n#+end_{name}"), &NoLinks);
            assert!(closed.contains(&escape(body)), "{name}: {closed}");
            let open = to_html(
                &format!("#+begin_{name}\n{body}\n\u{e9}\u{e9}\u{e9}"),
                &NoLinks,
            );
            assert!(open.contains(body), "{name}: {open}");
        }
        // Every construct, with multi-byte characters at every position.
        let samples = [
            "* \u{e9}",
            "\u{e9}*b\u{e9}*\u{e9}",
            "- \u{e9} :: \u{e9}",
            "  \u{e9}",
            "1. \u{e9}",
            "| \u{e9} | \u{1F642} |",
            "|-\u{e9}",
            ": \u{e9}",
            ":\u{e9}:",
            "#+\u{e9}",
            "#+begin_\u{e9}",
            "[[\u{e9}][\u{e9}]]",
            "https://\u{e9}",
            "Z\u{e9}-1",
            "ZZ-1\u{e9}",
            "~\u{e9}~",
            "=\u{e9}",
            "\\\\\u{e9}",
            "- [\u{e9}] x",
            "\u{e9}-----",
        ];
        for a in samples {
            for b in samples {
                let text = format!("{a}\n{b}\n\n{b} {a}");
                to_html(&text, &NoLinks);
                let mut cut = String::new();
                for c in text.chars() {
                    cut.push(c);
                    to_html(&cut, &NoLinks);
                }
            }
        }
    }

    #[test]
    fn tables() {
        assert_eq!(
            html("| a | b |\n|---+---|\n| 1 | *2* |"),
            "<table>\n<thead>\n<tr><th>a</th><th>b</th></tr>\n</thead>\n<tbody>\n\
             <tr><td>1</td><td><strong>2</strong></td></tr>\n</tbody>\n</table>\n"
        );
        assert_eq!(
            html("| x |"),
            "<table>\n<tbody>\n<tr><td>x</td></tr>\n</tbody>\n</table>\n"
        );
    }

    #[test]
    fn unrecognised_constructs_are_preformatted() {
        assert_eq!(
            html("#+begin_verse\n  a <b>\n#+end_verse"),
            "<pre class=\"org\">#+begin_verse\n  a &lt;b&gt;\n#+end_verse</pre>\n"
        );
        assert_eq!(
            html(":PROPERTIES:\n:ID: x\n:END:"),
            "<pre class=\"org\">:PROPERTIES:\n:ID: x\n:END:</pre>\n"
        );
        assert_eq!(html("#+TITLE: t"), "<pre class=\"org\">#+TITLE: t</pre>\n");
        assert_eq!(
            html("#+begin_src\nno end"),
            "<pre class=\"org\">#+begin_src</pre>\n<p>no end</p>\n"
        );
        // Comment lines are dropped, as Org export drops them.
        assert_eq!(html("# private\nkept"), "<p>kept</p>\n");
    }
}

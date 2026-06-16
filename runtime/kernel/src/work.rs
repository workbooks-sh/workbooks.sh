//! The Work format — one mechanism: `element + values + nesting + prose`.
//!
//! Parses the `.work` shorthand into a generic [`Node`] tree and renders it to
//! `work-*` HTML, the canonical browser-native artifact. There is no document
//! model of its own: the shorthand is a 1:1 projection of the element tree,
//! the same way Pug/Slim project onto HTML. See docs/WORK-FORMAT.md.

use std::collections::BTreeMap;

/// A generic element node. Org's special fields (state, tags, drawers,
/// timestamps) are just attributes here — one mechanism for every concept.
#[derive(Debug, Clone, PartialEq)]
pub struct Node {
    pub tag: String,
    pub attrs: BTreeMap<String, String>,
    pub body: String,
    pub children: Vec<Node>,
}

impl Node {
    fn new(tag: String) -> Self {
        Node { tag, attrs: BTreeMap::new(), body: String::new(), children: vec![] }
    }
}

// ── Parse: `.work` shorthand → Node tree ───────────────────────────────────

/// Parse the shorthand into top-level nodes.
pub fn parse_work(src: &str) -> Vec<Node> {
    // Stack of (indent, open node). Prose attaches to the deepest open node.
    let mut stack: Vec<(usize, Node)> = vec![];
    let mut roots: Vec<Node> = vec![];

    for raw in src.lines() {
        if raw.trim().is_empty() {
            continue;
        }
        let indent = raw.len() - raw.trim_start().len();
        let line = raw.trim_start();

        match element_tag(line) {
            Some(tag_len) => {
                // Close any open nodes at this indent or deeper — they are done.
                while stack.last().map(|(i, _)| *i >= indent).unwrap_or(false) {
                    let (_, done) = stack.pop().unwrap();
                    attach(done, &mut stack, &mut roots);
                }
                let node = parse_element(&line[..tag_len], line[tag_len..].trim());
                stack.push((indent, node));
            }
            // Prose line → body of the deepest open element.
            None => {
                if let Some((_, top)) = stack.last_mut() {
                    if !top.body.is_empty() {
                        top.body.push('\n');
                    }
                    top.body.push_str(line);
                }
            }
        }
    }
    while let Some((_, done)) = stack.pop() {
        attach(done, &mut stack, &mut roots);
    }
    roots
}

fn attach(node: Node, stack: &mut [(usize, Node)], roots: &mut Vec<Node>) {
    match stack.last_mut() {
        Some((_, parent)) => parent.children.push(node),
        None => roots.push(node),
    }
}

/// If the line begins with a valid custom-element name (lowercase, contains a
/// hyphen — the spec requirement), return the tag length; otherwise it's prose.
/// This is the whole element-vs-prose rule: prose words have no hyphen.
fn element_tag(line: &str) -> Option<usize> {
    let tok = line.split_whitespace().next()?;
    if is_custom_element(tok) {
        Some(tok.len())
    } else {
        None
    }
}

fn is_custom_element(tok: &str) -> bool {
    let mut chars = tok.chars();
    match chars.next() {
        Some(c) if c.is_ascii_lowercase() => {}
        _ => return false,
    }
    let mut hyphen = false;
    for c in chars {
        if c == '-' {
            hyphen = true;
        } else if !c.is_ascii_lowercase() && !c.is_ascii_digit() {
            return false;
        }
    }
    hyphen
}

fn parse_element(tag: &str, rest: &str) -> Node {
    let mut node = Node::new(tag.to_string());
    for tok in tokenize(rest) {
        if let Some(name) = tok.strip_prefix('@') {
            // value-primitive sugar: @name → assignee="name"
            node.attrs.insert("assignee".into(), unquote(name));
        } else if let Some((k, v)) = split_attr(&tok) {
            node.attrs.insert(k, unquote(&v));
        } else if tok.starts_with('"') {
            // first bare quoted string is the title / default slot
            node.attrs.entry("title".into()).or_insert_with(|| unquote(&tok));
        } else {
            // bare word → boolean attribute (present)
            node.attrs.insert(tok, String::new());
        }
    }
    node
}

/// Split into whitespace tokens, keeping `"…"` (incl. embedded spaces) whole.
fn tokenize(s: &str) -> Vec<String> {
    let mut toks = vec![];
    let mut cur = String::new();
    let mut in_q = false;
    for ch in s.chars() {
        match ch {
            '"' => {
                in_q = !in_q;
                cur.push('"');
            }
            c if c.is_whitespace() && !in_q => {
                if !cur.is_empty() {
                    toks.push(std::mem::take(&mut cur));
                }
            }
            c => cur.push(c),
        }
    }
    if !cur.is_empty() {
        toks.push(cur);
    }
    toks
}

/// `key=val` → (key, val). Only when the part before `=` is a bare attr name
/// (no leading quote), so a quoted title isn't mistaken for an attribute.
fn split_attr(tok: &str) -> Option<(String, String)> {
    let eq = tok.find('=')?;
    let (k, v) = (&tok[..eq], &tok[eq + 1..]);
    if k.is_empty() || k.starts_with('"') || !k.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_') {
        return None;
    }
    Some((k.to_string(), v.to_string()))
}

fn unquote(s: &str) -> String {
    let s = s.trim();
    if s.len() >= 2 && s.starts_with('"') && s.ends_with('"') {
        s[1..s.len() - 1].to_string()
    } else {
        s.to_string()
    }
}

// ── Render: Node tree → work-* HTML (the canonical artifact) ────────────────

/// Parse the shorthand and render it to `work-*` HTML.
pub fn render_work(src: &str) -> String {
    let mut out = String::new();
    for node in parse_work(src) {
        render_node(&node, 0, &mut out);
    }
    out
}

/// Render an already-built tree to HTML.
pub fn render_nodes(nodes: &[Node]) -> String {
    let mut out = String::new();
    for node in nodes {
        render_node(node, 0, &mut out);
    }
    out
}

fn render_node(n: &Node, depth: usize, out: &mut String) {
    let pad = "  ".repeat(depth);
    out.push_str(&pad);
    out.push('<');
    out.push_str(&n.tag);
    // attributes are sorted (BTreeMap) → byte-stable output
    for (k, v) in &n.attrs {
        out.push(' ');
        out.push_str(k);
        if !v.is_empty() {
            out.push_str("=\"");
            out.push_str(&escape_attr(v));
            out.push('"');
        }
    }
    if n.body.is_empty() && n.children.is_empty() {
        out.push_str("></");
        out.push_str(&n.tag);
        out.push_str(">\n");
        return;
    }
    out.push_str(">\n");
    if !n.body.is_empty() {
        // The component renders markdown in its shadow DOM; we emit escaped text.
        out.push_str(&"  ".repeat(depth + 1));
        out.push_str(&escape_text(&n.body));
        out.push('\n');
    }
    for c in &n.children {
        render_node(c, depth + 1, out);
    }
    out.push_str(&pad);
    out.push_str("</");
    out.push_str(&n.tag);
    out.push_str(">\n");
}

fn escape_attr(s: &str) -> String {
    s.replace('&', "&amp;").replace('"', "&quot;").replace('<', "&lt;")
}

fn escape_text(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"
work-sprint "Sprint 24" start=2026-06-15 end=2026-06-29
  work-task "Ship the parser" status=todo @kai due=2026-06-22 estimate=3d
    Needs the renderer first. Blocks the demo.
  work-task "Wire the board" status=done
"#;

    #[test]
    fn parses_nesting_and_attrs() {
        let roots = parse_work(SAMPLE);
        assert_eq!(roots.len(), 1);
        let sprint = &roots[0];
        assert_eq!(sprint.tag, "work-sprint");
        assert_eq!(sprint.attrs.get("title").unwrap(), "Sprint 24");
        assert_eq!(sprint.attrs.get("start").unwrap(), "2026-06-15");
        assert_eq!(sprint.children.len(), 2);

        let t1 = &sprint.children[0];
        assert_eq!(t1.tag, "work-task");
        assert_eq!(t1.attrs.get("title").unwrap(), "Ship the parser");
        assert_eq!(t1.attrs.get("status").unwrap(), "todo");
        assert_eq!(t1.attrs.get("assignee").unwrap(), "kai"); // @kai sugar
        assert_eq!(t1.attrs.get("estimate").unwrap(), "3d");
        assert_eq!(t1.body, "Needs the renderer first. Blocks the demo.");

        let t2 = &sprint.children[1];
        assert_eq!(t2.attrs.get("status").unwrap(), "done");
        assert!(t2.body.is_empty());
    }

    #[test]
    fn prose_word_is_not_an_element() {
        // "Needs" has no hyphen → prose, not a tag.
        assert!(element_tag("Needs the renderer").is_none());
        assert_eq!(element_tag("work-task x").unwrap(), 9);
    }

    #[test]
    fn renders_work_html() {
        let html = render_work(SAMPLE);
        assert!(html.contains("<work-sprint end=\"2026-06-29\" start=\"2026-06-15\" title=\"Sprint 24\">"));
        assert!(html.contains("<work-task assignee=\"kai\""));
        assert!(html.contains("status=\"done\" title=\"Wire the board\"></work-task>"));
        assert!(html.contains("Needs the renderer first. Blocks the demo."));
    }

    #[test]
    fn escapes_markup() {
        let html = render_work("work-note title=\"a < b & \\\"c\\\"\"\n  x < y & z");
        assert!(html.contains("&lt;"));
        assert!(html.contains("&amp;"));
    }
}

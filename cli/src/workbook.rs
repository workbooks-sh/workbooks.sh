//! HTML-native workbook reader (CLI side, dep-free).
//!
//! A workbook IS an HTML file built from `work-*` web components. The CLI reads
//! its STRUCTURE — the `work-*` element tree — with a small standard-shaped HTML
//! scanner (no kernel, no wasm). It mirrors `Workbooks.Workbook` (Elixir/Floki):
//!
//!   * `parse_headlines` : the outline — every `work-*` element as a row.
//!   * `tangle_plan`     : the build plan — `<work-flow>` worlds + `<work-component>`
//!                         leaves (source = element body, wiring = attributes).
//!   * `validate`        : diagnostics over the parsed component graph.
//!   * `render`          : a workbook IS HTML; render is the HTML itself (passthrough).
//!
//! The scanner only needs to recognise `work-*` tags; everything else is opaque
//! markup it descends through. Pure compute, identical on native + wasm targets.

use serde_json::{json, Value};
use std::collections::BTreeMap;

const RESERVED: &[&str] = &[
    "id", "title", "status", "tag", "assignee", "lang", "in", "out", "deps", "uses", "persist",
    "dir", "due", "scheduled", "at", "start", "end", "cron", "repeat",
];

#[derive(Debug, Clone)]
struct Node {
    tag: String,
    attrs: BTreeMap<String, String>,
    body: String,
    children: Vec<Node>,
}

// ── Public API (JSON strings out, mirroring the Elixir surface) ────────────

pub fn parse_headlines(src: &str) -> String {
    let roots = parse_work_nodes(src);
    let mut rows = vec![];
    for n in &roots {
        flatten(n, 1, &mut rows);
    }
    let arr: Vec<Value> = rows.iter().map(|(level, n)| node_row(*level, n)).collect();
    serde_json::to_string(&arr).unwrap_or_else(|_| "[]".into())
}

// Diagnostics that aren't structural validation (currently none). The `lint`
// verb uses `validate`; kept for API parity with the Elixir surface.
#[allow(dead_code)]
pub fn lint(_src: &str) -> String {
    "[]".into()
}

pub fn tangle_plan(src: &str) -> String {
    let roots = parse_work_nodes(src);
    let worlds: Vec<Value> = match top_flows(&roots) {
        flows if !flows.is_empty() => flows.iter().map(|f| build_world(f)).collect(),
        _ => {
            let comps = all_components(&roots);
            if comps.is_empty() {
                vec![]
            } else {
                vec![build_world(&implicit_flow(comps))]
            }
        }
    };
    json!({ "worlds": worlds }).to_string()
}

pub fn validate(src: &str) -> String {
    let roots = parse_work_nodes(src);
    let flows: Vec<Node> = match top_flows(&roots) {
        flows if !flows.is_empty() => flows.into_iter().cloned().collect(),
        _ => {
            let comps = all_components(&roots);
            if comps.is_empty() {
                vec![]
            } else {
                vec![implicit_flow(comps)]
            }
        }
    };

    let mut diags = vec![];
    for flow in &flows {
        let comps = comps_of(flow);
        let produced: std::collections::BTreeSet<&str> =
            comps.iter().filter_map(|c| c.out.as_deref()).collect();
        for c in &comps {
            if c.lang.is_none() {
                diags.push(diag("error", &c.name, "component has no source block / language"));
            }
            if let Some(inp) = &c.inp {
                if !produced.contains(inp.as_str()) {
                    diags.push(diag(
                        "error",
                        &c.name,
                        &format!("input `{}` has no upstream producer", inp),
                    ));
                }
            }
        }
    }
    serde_json::to_string(&diags).unwrap_or_else(|_| "[]".into())
}

/// A workbook IS HTML — render returns the HTML itself (passthrough). The browser
/// + the `work-*` Lit components do the visual render.
pub fn render(src: &str) -> String {
    src.to_string()
}

// ── HTML → work-* node tree (minimal scanner) ──────────────────────────────

fn parse_work_nodes(src: &str) -> Vec<Node> {
    let toks = tokenize(src);
    let mut pos = 0;
    let mut roots = vec![];
    while pos < toks.len() {
        if let Some((node, next)) = parse_node(&toks, pos) {
            if node.tag.starts_with("work-") {
                roots.push(node);
            } else {
                // descend: a non-work element may wrap work-* children.
                roots.extend(node.children);
            }
            pos = next;
        } else {
            pos += 1;
        }
    }
    roots
}

#[derive(Debug, Clone)]
enum Tok {
    Open(String, BTreeMap<String, String>, bool), // tag, attrs, self_closing
    Close(String),
    Text(String),
}

fn tokenize(src: &str) -> Vec<Tok> {
    let bytes: Vec<char> = src.chars().collect();
    let mut i = 0;
    let mut out = vec![];
    let mut text = String::new();

    while i < bytes.len() {
        if bytes[i] == '<' {
            // flush pending text
            if !text.is_empty() {
                out.push(Tok::Text(std::mem::take(&mut text)));
            }
            // find the matching '>'
            let start = i;
            let mut j = i + 1;
            let mut in_q: Option<char> = None;
            while j < bytes.len() {
                let c = bytes[j];
                match in_q {
                    Some(q) if c == q => in_q = None,
                    Some(_) => {}
                    None if c == '"' || c == '\'' => in_q = Some(c),
                    None if c == '>' => break,
                    None => {}
                }
                j += 1;
            }
            if j >= bytes.len() {
                // unterminated tag — treat the rest as text and stop.
                text.extend(&bytes[start..]);
                break;
            }
            let raw: String = bytes[start + 1..j].iter().collect();
            i = j + 1;
            if let Some(tok) = parse_tag(&raw) {
                out.push(tok);
            }
            // comments / doctype / processing instrs → dropped (parse_tag → None)
        } else {
            text.push(bytes[i]);
            i += 1;
        }
    }
    if !text.is_empty() {
        out.push(Tok::Text(text));
    }
    out
}

fn parse_tag(raw: &str) -> Option<Tok> {
    let raw = raw.trim();
    if raw.is_empty() || raw.starts_with('!') || raw.starts_with('?') {
        return None;
    }
    if let Some(rest) = raw.strip_prefix('/') {
        return Some(Tok::Close(rest.trim().to_lowercase()));
    }
    let self_closing = raw.ends_with('/');
    let body = raw.trim_end_matches('/').trim();

    // tag name = up to first whitespace
    let (name, attr_str) = match body.find(|c: char| c.is_whitespace()) {
        Some(idx) => (&body[..idx], &body[idx..]),
        None => (body, ""),
    };
    let attrs = parse_attrs(attr_str);
    Some(Tok::Open(name.to_lowercase(), attrs, self_closing))
}

fn parse_attrs(s: &str) -> BTreeMap<String, String> {
    let chars: Vec<char> = s.chars().collect();
    let mut i = 0;
    let mut attrs = BTreeMap::new();
    while i < chars.len() {
        while i < chars.len() && chars[i].is_whitespace() {
            i += 1;
        }
        if i >= chars.len() {
            break;
        }
        // read name
        let nstart = i;
        while i < chars.len() && chars[i] != '=' && !chars[i].is_whitespace() {
            i += 1;
        }
        let name: String = chars[nstart..i].iter().collect::<String>().to_lowercase();
        if name.is_empty() {
            i += 1;
            continue;
        }
        // optional = value
        while i < chars.len() && chars[i].is_whitespace() {
            i += 1;
        }
        if i < chars.len() && chars[i] == '=' {
            i += 1;
            while i < chars.len() && chars[i].is_whitespace() {
                i += 1;
            }
            let val = if i < chars.len() && (chars[i] == '"' || chars[i] == '\'') {
                let q = chars[i];
                i += 1;
                let vstart = i;
                while i < chars.len() && chars[i] != q {
                    i += 1;
                }
                let v: String = chars[vstart..i].iter().collect();
                if i < chars.len() {
                    i += 1; // closing quote
                }
                v
            } else {
                let vstart = i;
                while i < chars.len() && !chars[i].is_whitespace() {
                    i += 1;
                }
                chars[vstart..i].iter().collect()
            };
            attrs.insert(name, html_unescape(&val));
        } else {
            // boolean attribute
            attrs.insert(name, String::new());
        }
    }
    attrs
}

fn html_unescape(s: &str) -> String {
    s.replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&amp;", "&")
}

// Recursive-descent over the flat token stream → a Node (and the next index).
fn parse_node(toks: &[Tok], pos: usize) -> Option<(Node, usize)> {
    match toks.get(pos)? {
        Tok::Open(tag, attrs, self_closing) => {
            let mut node = Node {
                tag: tag.clone(),
                attrs: attrs.clone(),
                body: String::new(),
                children: vec![],
            };
            if *self_closing || is_void(tag) {
                return Some((node, pos + 1));
            }
            let mut i = pos + 1;
            while i < toks.len() {
                match &toks[i] {
                    Tok::Close(close) if close == tag => {
                        return Some((node, i + 1));
                    }
                    Tok::Close(_) => {
                        // stray/mismatched close — skip it.
                        i += 1;
                    }
                    Tok::Text(t) => {
                        node.body.push_str(t);
                        i += 1;
                    }
                    Tok::Open(..) => {
                        if let Some((child, next)) = parse_node(toks, i) {
                            if child.tag.starts_with("work-") {
                                node.children.push(child);
                            } else {
                                // flatten non-work descendants up so nested work-*
                                // elements are still discovered.
                                node.children.extend(child.children);
                            }
                            i = next;
                        } else {
                            i += 1;
                        }
                    }
                }
            }
            // unterminated element — accept what we have.
            Some((node, i))
        }
        _ => None,
    }
}

fn is_void(tag: &str) -> bool {
    matches!(
        tag,
        "area" | "base" | "br" | "col" | "embed" | "hr" | "img" | "input" | "link" | "meta"
            | "param" | "source" | "track" | "wbr"
    )
}

// ── Row shape for parse_headlines ──────────────────────────────────────────

fn flatten<'a>(n: &'a Node, level: usize, out: &mut Vec<(usize, &'a Node)>) {
    out.push((level, n));
    for c in &n.children {
        flatten(c, level + 1, out);
    }
}

fn node_row(level: usize, n: &Node) -> Value {
    let status = n.attrs.get("status").map(|s| s.to_uppercase());
    let tags: Vec<&str> = n
        .attrs
        .get("tag")
        .map(|t| t.split_whitespace().collect())
        .unwrap_or_default();
    let props: BTreeMap<String, &String> = n
        .attrs
        .iter()
        .filter(|(k, _)| !RESERVED.contains(&k.as_str()))
        .map(|(k, v)| (k.to_uppercase(), v))
        .collect();

    json!({
        "level": level,
        "title": n.attrs.get("title").cloned().unwrap_or_default(),
        "status": status,
        "state": status,
        "id": n.attrs.get("id"),
        "tag": n.attrs.get("tag"),
        "tags": tags,
        "props": props,
        "lang": n.attrs.get("lang"),
        "in": n.attrs.get("in"),
        "out": n.attrs.get("out"),
        "dir": n.attrs.get("dir"),
        "tagname": n.tag,
    })
}

// ── Components + build plan ─────────────────────────────────────────────────

struct Comp {
    name: String,
    lang: Option<String>,
    deps: Vec<String>,
    uses: Vec<String>,
    inp: Option<String>,
    out: Option<String>,
    persist: bool,
    src: String,
    dir: Option<String>,
}

fn is_flow(n: &Node) -> bool {
    n.tag == "work-flow"
}
fn is_component(n: &Node) -> bool {
    n.tag == "work-component"
}

fn top_flows(nodes: &[Node]) -> Vec<&Node> {
    let mut out = vec![];
    for n in nodes {
        if is_flow(n) {
            out.push(n);
        } else {
            out.extend(top_flows(&n.children));
        }
    }
    out
}

fn all_components(nodes: &[Node]) -> Vec<Node> {
    let mut out = vec![];
    for n in nodes {
        if is_component(n) {
            out.push(n.clone());
        }
        out.extend(all_components(&n.children));
    }
    out
}

fn implicit_flow(components: Vec<Node>) -> Node {
    Node {
        tag: "work-flow".into(),
        attrs: BTreeMap::new(),
        body: String::new(),
        children: components,
    }
}

fn list_attr(n: &Node, key: &str) -> Vec<String> {
    match n.attrs.get(key) {
        Some(v) if !v.is_empty() => v.split(',').map(|s| s.trim().to_string()).collect(),
        _ => vec![],
    }
}

fn opt_attr(n: &Node, key: &str) -> Option<String> {
    n.attrs.get(key).filter(|v| !v.is_empty()).cloned()
}

fn comp_of(n: &Node) -> Comp {
    Comp {
        name: n.attrs.get("title").cloned().unwrap_or_default(),
        lang: n.attrs.get("lang").cloned(),
        deps: list_attr(n, "deps"),
        uses: list_attr(n, "uses"),
        inp: opt_attr(n, "in"),
        out: opt_attr(n, "out"),
        persist: n.attrs.contains_key("persist"),
        src: n.body.trim().to_string(),
        dir: opt_attr(n, "dir"),
    }
}

fn comps_of(flow: &Node) -> Vec<Comp> {
    fn go(nodes: &[Node], out: &mut Vec<Comp>) {
        for n in nodes {
            if is_component(n) {
                out.push(comp_of(n));
            }
            go(&n.children, out);
        }
    }
    let mut out = vec![];
    go(&flow.children, &mut out);
    out
}

fn build_world(flow: &Node) -> Value {
    let mut comps = vec![];
    let mut subworlds = vec![];
    for child in &flow.children {
        if is_flow(child) {
            subworlds.push(build_world(child));
        } else if is_component(child) {
            comps.push(comp_of(child));
        }
    }
    let (imports, exports, edges) = sig_of(&comps);
    let components: Vec<Value> = comps.iter().map(comp_json).collect();
    let edges: Vec<Value> = edges
        .iter()
        .map(|(f, t)| json!({ "from": f, "to": t }))
        .collect();
    json!({
        "name": flow.attrs.get("title").cloned().unwrap_or_default(),
        "imports": imports,
        "exports": exports,
        "components": components,
        "edges": edges,
        "workflows": subworlds,
    })
}

fn sig_of(comps: &[Comp]) -> (Vec<String>, Vec<String>, Vec<(String, String)>) {
    let mut imports: Vec<String> = comps.iter().flat_map(|c| c.uses.clone()).collect();
    imports.sort();
    imports.dedup();

    let mut producer: BTreeMap<String, String> = BTreeMap::new();
    for c in comps {
        if let Some(o) = &c.out {
            producer.insert(o.clone(), c.name.clone());
        }
    }
    let mut edges = vec![];
    let mut consumed = std::collections::BTreeSet::new();
    for c in comps {
        if let Some(i) = &c.inp {
            if let Some(f) = producer.get(i) {
                edges.push((f.clone(), c.name.clone()));
                consumed.insert(i.clone());
            }
        }
    }
    let mut exports: Vec<String> = comps
        .iter()
        .filter_map(|c| c.out.clone())
        .filter(|o| !consumed.contains(o))
        .collect();
    exports.sort();
    exports.dedup();
    (imports, exports, edges)
}

fn comp_json(c: &Comp) -> Value {
    json!({
        "name": c.name, "lang": c.lang, "deps": c.deps, "uses": c.uses,
        "in": c.inp, "out": c.out, "persist": c.persist, "src": c.src, "dir": c.dir,
    })
}

fn diag(level: &str, scope: &str, msg: &str) -> Value {
    json!({ "level": level, "scope": scope, "message": msg })
}

#[cfg(test)]
mod tests {
    use super::*;

    const FLOW: &str = r#"
<work-flow title="etl">
  <work-component title="extract" lang="rust" out="raw"></work-component>
  <work-component title="transform" lang="rust" in="raw" out="clean" uses="fetch"></work-component>
  <work-component title="load" lang="rust" in="clean"></work-component>
</work-flow>
"#;

    #[test]
    fn parse_headlines_shape() {
        let json: Value = serde_json::from_str(&parse_headlines(FLOW)).unwrap();
        let rows = json.as_array().unwrap();
        assert_eq!(rows.len(), 4);
        assert_eq!(rows[0]["level"], 1);
        assert_eq!(rows[0]["title"], "etl");
        assert_eq!(rows[1]["level"], 2);
        assert_eq!(rows[1]["title"], "extract");
    }

    #[test]
    fn tangle_plan_world_and_edges() {
        let plan: Value = serde_json::from_str(&tangle_plan(FLOW)).unwrap();
        let worlds = plan["worlds"].as_array().unwrap();
        assert_eq!(worlds.len(), 1);
        let w = &worlds[0];
        assert_eq!(w["name"], "etl");
        assert_eq!(w["components"].as_array().unwrap().len(), 3);
        assert_eq!(w["imports"], json!(["fetch"]));
        let edges = w["edges"].as_array().unwrap();
        assert!(edges
            .iter()
            .any(|e| e["from"] == "extract" && e["to"] == "transform"));
    }

    #[test]
    fn validate_flags_dangling_and_langless() {
        let src = r#"<work-flow title="b">
          <work-component title="needs" lang="js" in="missing"></work-component>
          <work-component title="nolang"></work-component>
        </work-flow>"#;
        let diags: Value = serde_json::from_str(&validate(src)).unwrap();
        let msgs: Vec<String> = diags
            .as_array()
            .unwrap()
            .iter()
            .map(|d| d["message"].as_str().unwrap().to_string())
            .collect();
        assert!(msgs.iter().any(|m| m.contains("no upstream producer")));
        assert!(msgs.iter().any(|m| m.contains("no source block")));
    }

    #[test]
    fn validate_clean_is_empty() {
        assert_eq!(
            validate(r#"<work-doc title="t"><p>x</p></work-doc>"#),
            "[]"
        );
    }

    #[test]
    fn render_is_passthrough() {
        let html = r#"<work-doc title="Hi"><p>body</p></work-doc>"#;
        assert_eq!(render(html), html);
    }

    #[test]
    fn component_body_is_source() {
        let src = r#"<work-flow title="f"><work-component title="add" lang="rust" out="sum" dir="crates/add">pub fn add() {}</work-component></work-flow>"#;
        let plan: Value = serde_json::from_str(&tangle_plan(src)).unwrap();
        let comp = &plan["worlds"][0]["components"][0];
        assert_eq!(comp["name"], "add");
        assert_eq!(comp["dir"], "crates/add");
        assert!(comp["src"].as_str().unwrap().contains("pub fn add"));
    }

    #[test]
    fn descends_through_non_work_wrappers() {
        let json: Value =
            serde_json::from_str(&parse_headlines(r#"<div><work-note title="Inner"></work-note></div>"#))
                .unwrap();
        let rows = json.as_array().unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0]["title"], "Inner");
        assert_eq!(rows[0]["level"], 1);
    }
}

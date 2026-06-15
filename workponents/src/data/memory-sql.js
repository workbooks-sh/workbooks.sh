// workponents · data — the in-JS fallback engine (zero-dep, offline).
//
// A small SQL-subset interpreter so the surfaces compute REAL sort/filter/aggregate
// IN an engine even with no runtime tier AND no network (CDN blocked). It is the
// LAST RESORT behind ./engine.js — when the runtime VFS (Host) or in-page
// sqlite-wasm is reachable, real SQLite answers instead and this is never touched.
// It is a SUBSET (no CAST, joins, window fns) — not real SQLite; prefer the tiers.
//
// Supported (one flat table per query, the basic grid/chart/geo-query needs):
//   SELECT <proj> FROM <table>
//     [WHERE <cond> [AND/OR <cond>]...]
//     [GROUP BY <col>[, <col>]...]
//     [ORDER BY <col|alias> [ASC|DESC]][, ...]
//     [LIMIT n [OFFSET m]]
//   proj: *, col, col AS alias, AGG(col) [AS alias], COUNT(*)
//   agg:  COUNT | SUM | AVG | MIN | MAX
//   cond: col OP value   OP ∈ = != <> < <= > >= LIKE   value: number|'str'|?
//   ? params bind positionally (SQLite style).
//
// Deliberately small. For anything beyond this, a real engine is required — the
// element degrades by surfacing the engine name so authors know which tier ran.

import { resultFromObjects } from "./contract.js";

const AGG_RE = /^(count|sum|avg|min|max)\s*\(\s*(\*|[\w."]+)\s*\)$/i;

export class MemorySql {
  constructor() {
    /** @type {Map<string,{columns:string[],rows:object[]}>} */
    this.tables = new Map();
  }

  register(name, normalized) {
    this.tables.set(name, normalized);
  }

  /** query(sql, params?) -> WbQueryResult */
  query(sql, params = []) {
    const q = parse(sql);
    const tbl = this.tables.get(q.from);
    if (!tbl) throw new Error(`wb-data(memory): unknown table "${q.from}"`);
    let rows = tbl.rows.slice();
    const binds = params.slice();

    // WHERE
    if (q.where.length) {
      rows = rows.filter((r) => evalWhere(r, q.where, binds.slice()));
    }

    let out;
    const hasAgg = q.select.some((s) => s.agg);
    if (q.groupBy.length || hasAgg) {
      out = aggregate(rows, q);
    } else {
      out = rows.map((r) => projectRow(r, q.select, tbl.columns));
    }

    // ORDER BY (by output alias/name)
    for (let i = q.orderBy.length - 1; i >= 0; i--) {
      const { key, dir } = q.orderBy[i];
      out.sort((a, b) => cmp(a[key], b[key]) * (dir === "desc" ? -1 : 1));
    }

    // LIMIT / OFFSET
    if (q.offset) out = out.slice(q.offset);
    if (q.limit != null) out = out.slice(0, q.limit);

    const columns = q.star ? (out[0] ? Object.keys(out[0]) : tbl.columns) : q.select.map((s) => s.alias);
    return resultFromObjects(out, columns, "memory", sql);
  }
}

function projectRow(r, select, allCols) {
  const o = {};
  for (const s of select) {
    if (s.star) { for (const c of allCols) o[c] = r[c]; continue; }
    o[s.alias] = r[s.col];
  }
  return o;
}

function aggregate(rows, q) {
  const groupCols = q.groupBy;
  const groups = new Map();
  for (const r of rows) {
    const key = groupCols.map((c) => r[c]).join("");
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(r);
  }
  if (!groups.size && !groupCols.length) groups.set("", []); // global agg over empty set
  const out = [];
  for (const bucket of groups.values()) {
    const o = {};
    for (const s of q.select) {
      if (s.star && !s.agg) { for (const c of groupCols) o[c] = bucket[0]?.[c]; continue; }
      if (s.agg) o[s.alias] = applyAgg(s.agg, s.col, bucket);
      else o[s.alias] = bucket[0]?.[s.col] ?? null; // grouping column
    }
    out.push(o);
  }
  return out;
}

function applyAgg(agg, col, bucket) {
  if (agg === "count") return col === "*" ? bucket.length : bucket.filter((r) => r[col] != null).length;
  const nums = bucket.map((r) => Number(r[col])).filter((n) => !Number.isNaN(n));
  if (!nums.length) return null;
  if (agg === "sum") return nums.reduce((a, b) => a + b, 0);
  if (agg === "avg") return nums.reduce((a, b) => a + b, 0) / nums.length;
  if (agg === "min") return Math.min(...nums);
  if (agg === "max") return Math.max(...nums);
  return null;
}

function cmp(a, b) {
  if (a == null && b == null) return 0;
  if (a == null) return -1;
  if (b == null) return 1;
  if (typeof a === "number" && typeof b === "number") return a - b;
  return String(a).localeCompare(String(b), undefined, { numeric: true });
}

function evalWhere(row, clauses, binds) {
  // clauses: [cond, {bool}, cond, ...] — left-to-right, AND/OR (no precedence/parens)
  let acc = null, op = "and";
  for (const node of clauses) {
    if (node.bool) { op = node.bool; continue; }
    const v = testCond(row, node, binds);
    acc = acc == null ? v : op === "and" ? acc && v : acc || v;
  }
  return acc == null ? true : acc;
}

function testCond(row, c, binds) {
  const lhs = row[c.col];
  const rhs = c.param ? binds.shift() : c.value;
  switch (c.op) {
    case "=": return looseEq(lhs, rhs);
    case "!=": case "<>": return !looseEq(lhs, rhs);
    case "<": return num(lhs) < num(rhs);
    case "<=": return num(lhs) <= num(rhs);
    case ">": return num(lhs) > num(rhs);
    case ">=": return num(lhs) >= num(rhs);
    case "like": return likeMatch(String(lhs ?? ""), String(rhs ?? ""));
    default: return false;
  }
}

function looseEq(a, b) {
  if (typeof a === "number" || typeof b === "number") return num(a) === num(b);
  return String(a) === String(b);
}
function num(v) { const n = Number(v); return Number.isNaN(n) ? v : n; }
function likeMatch(s, pat) {
  const re = new RegExp("^" + pat.replace(/[.*+?^${}()|[\]\\]/g, "\\$&").replace(/%/g, ".*").replace(/_/g, ".") + "$", "i");
  return re.test(s);
}

// ── parser ───────────────────────────────────────────────────────────────────
function parse(sql) {
  const s = sql.trim().replace(/;$/, "");
  const m = /^select\s+(.+?)\s+from\s+([\w."]+)(.*)$/is.exec(s);
  if (!m) throw new Error("wb-data(memory): only SELECT … FROM … is supported");
  const projRaw = m[1], from = unquote(m[2]);
  let rest = m[3] || "";

  const where = [], groupBy = [], orderBy = [];
  let limit = null, offset = 0;

  const limitM = /\blimit\s+(\d+)(?:\s+offset\s+(\d+))?/i.exec(rest);
  if (limitM) { limit = +limitM[1]; offset = limitM[2] ? +limitM[2] : 0; rest = rest.replace(limitM[0], ""); }
  const offM = /\boffset\s+(\d+)/i.exec(rest);
  if (offM) { offset = +offM[1]; rest = rest.replace(offM[0], ""); }

  const orderM = /\border\s+by\s+(.+?)(?=\bgroup\s+by\b|$)/is.exec(rest);
  if (orderM) {
    rest = rest.replace(orderM[0], "");
    for (const part of orderM[1].split(",")) {
      const [, key, dir] = /^\s*([\w."]+)\s*(asc|desc)?\s*$/i.exec(part) || [];
      if (key) orderBy.push({ key: unquote(key), dir: (dir || "asc").toLowerCase() });
    }
  }
  const groupM = /\bgroup\s+by\s+(.+?)(?=\border\s+by\b|$)/is.exec(rest);
  if (groupM) {
    rest = rest.replace(groupM[0], "");
    for (const p of groupM[1].split(",")) groupBy.push(unquote(p.trim()));
  }
  const whereM = /\bwhere\s+(.+)$/is.exec(rest);
  if (whereM) parseWhere(whereM[1].trim(), where);

  const select = [];
  let star = false;
  for (const raw of splitTop(projRaw)) {
    const item = raw.trim();
    if (item === "*") { select.push({ star: true }); star = true; continue; }
    const asM = /\s+as\s+([\w]+)\s*$/i.exec(item);
    const alias = asM ? asM[1] : null;
    const expr = asM ? item.slice(0, asM.index).trim() : item;
    const aggM = AGG_RE.exec(expr);
    if (aggM) {
      const agg = aggM[1].toLowerCase();
      const col = aggM[2] === "*" ? "*" : unquote(aggM[2]);
      select.push({ agg, col, alias: alias || `${agg}_${col === "*" ? "all" : col}` });
    } else {
      const col = unquote(expr);
      select.push({ col, alias: alias || col });
    }
  }
  return { select, star, from, where, groupBy, orderBy, limit, offset };
}

function parseWhere(str, out) {
  // split on top-level AND/OR (no parens support — flat list)
  const parts = str.split(/\s+(and|or)\s+/i);
  for (let i = 0; i < parts.length; i++) {
    if (i % 2 === 1) { out.push({ bool: parts[i].toLowerCase() }); continue; }
    const m = /^\s*([\w."]+)\s*(<=|>=|<>|!=|=|<|>|like)\s*(.+?)\s*$/i.exec(parts[i]);
    if (!m) throw new Error(`wb-data(memory): bad WHERE clause "${parts[i]}"`);
    const col = unquote(m[1]), op = m[2].toLowerCase();
    let value = m[3].trim(), param = false;
    if (value === "?") param = true;
    else if (/^'.*'$/.test(value)) value = value.slice(1, -1).replace(/''/g, "'");
    else if (/^-?\d*\.?\d+$/.test(value)) value = parseFloat(value);
    out.push({ col, op, value, param });
  }
}

function splitTop(s) {
  // split on commas not inside parentheses
  const out = []; let depth = 0, cur = "";
  for (const c of s) {
    if (c === "(") depth++;
    else if (c === ")") depth--;
    if (c === "," && depth === 0) { out.push(cur); cur = ""; } else cur += c;
  }
  if (cur.trim()) out.push(cur);
  return out;
}

function unquote(s) { return String(s).trim().replace(/^"(.*)"$/, "$1"); }

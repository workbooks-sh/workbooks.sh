#!/usr/bin/env bun
// Parse packages/schema/migrations/*.sql and emit a markdown reference.
// Output: docs/schema.md (path passed as argv[2], default ../../docs/schema.md).
//
// Parser is intentionally lightweight — it handles the subset of SQLite DDL
// our migrations actually use: CREATE TABLE IF NOT EXISTS, single-line
// column defs, REFERENCES … ON DELETE …, UNIQUE(...) table constraints,
// CREATE INDEX IF NOT EXISTS. We re-run it manually after schema changes.

import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const MIGRATIONS_DIR = resolve(SCRIPT_DIR, "..", "migrations");
const REPO_ROOT = resolve(SCRIPT_DIR, "..", "..", "..");
const DEFAULT_OUT = resolve(REPO_ROOT, "docs", "schema.md");

interface Column {
  name: string;
  type: string;
  nullable: boolean;
  primaryKey: boolean;
  unique: boolean;
  default?: string;
  references?: string;
  notes?: string;
}

interface Table {
  name: string;
  columns: Column[];
  uniqueConstraints: string[][];
  comment?: string;
}

interface IndexDef {
  name: string;
  table: string;
  columns: string;
}

function readAllSql(): string {
  const files = readdirSync(MIGRATIONS_DIR)
    .filter((f) => f.endsWith(".sql"))
    .sort();
  return files.map((f) => readFileSync(join(MIGRATIONS_DIR, f), "utf8")).join("\n");
}

function stripBlockComments(s: string): string {
  return s.replace(/--[^\n]*\n/g, "\n");
}

function parseTables(sql: string): { tables: Table[]; indexes: IndexDef[] } {
  const tables: Table[] = [];
  const indexes: IndexDef[] = [];
  const cleaned = stripBlockComments(sql);

  const tableRe = /CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+)\s*\(([\s\S]*?)\);/gi;
  for (const m of cleaned.matchAll(tableRe)) {
    const [, name, body] = m;
    if (name && body) tables.push(parseTable(name, body));
  }

  const idxRe =
    /CREATE\s+(?:UNIQUE\s+)?INDEX\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+)\s+ON\s+(\w+)\s*\(([^)]+)\)/gi;
  for (const i of cleaned.matchAll(idxRe)) {
    const [, name, table, columns] = i;
    if (name && table && columns) {
      indexes.push({ name, table, columns: columns.trim() });
    }
  }
  return { tables, indexes };
}

function splitTopLevelCommas(body: string): string[] {
  const parts: string[] = [];
  let depth = 0;
  let current = "";
  for (const ch of body) {
    if (ch === "(") depth++;
    else if (ch === ")") depth--;
    if (ch === "," && depth === 0) {
      parts.push(current.trim());
      current = "";
    } else {
      current += ch;
    }
  }
  if (current.trim()) parts.push(current.trim());
  return parts;
}

function parseTable(name: string, body: string): Table {
  const lines = splitTopLevelCommas(body);
  const columns: Column[] = [];
  const uniqueConstraints: string[][] = [];

  for (const line of lines) {
    const upper = line.toUpperCase();
    if (upper.startsWith("PRIMARY KEY") || upper.startsWith("FOREIGN KEY")) {
      continue;
    }
    if (upper.startsWith("UNIQUE(") || upper.startsWith("UNIQUE (")) {
      const inner = line.slice(line.indexOf("(") + 1, line.lastIndexOf(")"));
      uniqueConstraints.push(inner.split(",").map((c) => c.trim()));
      continue;
    }
    const tokenMatch = /^(\w+)\s+([A-Z]+)(.*)$/i.exec(line);
    if (!tokenMatch) continue;
    const colName = tokenMatch[1];
    const colType = tokenMatch[2];
    const rest = tokenMatch[3] ?? "";
    if (!colName || !colType) continue;
    const r = rest.toUpperCase();
    const refMatch =
      /REFERENCES\s+(\w+)\s*\((\w+)\)(?:\s+ON\s+DELETE\s+([A-Z\s]+?))?(?=\s|$)/i.exec(rest);
    const defaultMatch = /DEFAULT\s+([^\s]+)/i.exec(rest);
    columns.push({
      name: colName,
      type: colType,
      nullable: !r.includes("NOT NULL") && !r.includes("PRIMARY KEY"),
      primaryKey: r.includes("PRIMARY KEY"),
      unique: r.includes(" UNIQUE") || r.endsWith("UNIQUE"),
      default: defaultMatch?.[1],
      references: refMatch?.[1]
        ? `${refMatch[1]}.${refMatch[2]}${refMatch[3] ? ` (ON DELETE ${refMatch[3].trim()})` : ""}`
        : undefined,
    });
  }

  return { name, columns, uniqueConstraints };
}

function md(s: string): string {
  return s.replace(/\|/g, "\\|");
}

function renderTable(t: Table, indexes: IndexDef[]): string {
  const rows = [
    "| Column | Type | Null | Notes |",
    "| --- | --- | --- | --- |",
    ...t.columns.map((c) => {
      const notes: string[] = [];
      if (c.primaryKey) notes.push("primary key");
      if (c.unique) notes.push("unique");
      if (c.default !== undefined) notes.push(`default \`${c.default}\``);
      if (c.references) notes.push(`→ ${c.references}`);
      return `| \`${c.name}\` | ${c.type} | ${c.nullable ? "yes" : "no"} | ${md(notes.join("; "))} |`;
    }),
  ];

  const lines = [`### \`${t.name}\``, "", ...rows];

  if (t.uniqueConstraints.length > 0) {
    const list = t.uniqueConstraints.map((c) => `(${c.join(", ")})`).join(", ");
    lines.push("", `**Unique constraints:** ${list}`);
  }

  const tableIndexes = indexes.filter((i) => i.table === t.name);
  if (tableIndexes.length > 0) {
    const list = tableIndexes.map((i) => `\`${i.name}\` on (${i.columns})`).join(", ");
    lines.push("", `**Indexes:** ${list}`);
  }
  return lines.join("\n");
}

function render(tables: Table[], indexes: IndexDef[]): string {
  const lines = [
    "# Brandnana SQLite schema reference",
    "",
    "_Auto-generated from `packages/schema/migrations/*.sql`._",
    "_Regenerate with `bun run --cwd packages/schema docs:gen`._",
    "",
    "## Tables",
    "",
    tables.map((t) => `- [\`${t.name}\`](#${t.name})`).join("\n"),
    "",
    ...tables.map((t) => renderTable(t, indexes)),
  ];
  return `${lines.join("\n\n")}\n`;
}

const outArg = process.argv[2];
const out = outArg ? resolve(process.cwd(), outArg) : DEFAULT_OUT;

const sql = readAllSql();
const { tables, indexes } = parseTables(sql);
writeFileSync(out, render(tables, indexes));
console.log(
  `✓ wrote schema reference: ${out} (${tables.length} tables, ${indexes.length} indexes)`,
);

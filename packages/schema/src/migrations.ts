import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const DEFAULT_MIGRATIONS_DIR = join(dirname(fileURLToPath(import.meta.url)), "..", "migrations");

const FILENAME_RE = /^(\d{4})_[a-z0-9_]+\.sql$/;

export interface Migration {
  filename: string;
  sequence: number;
  sql: string;
}

export interface MigrationRunner {
  exec(sql: string): void;
  prepare(sql: string): {
    get(...params: unknown[]): unknown;
    all(...params: unknown[]): unknown[];
    run(...params: unknown[]): unknown;
  };
  transaction<T>(fn: () => T): () => T;
}

export interface MigrationResult {
  applied: string[];
  skipped: string[];
  currentVersion: number;
}

export function loadMigrations(dir: string = DEFAULT_MIGRATIONS_DIR): Migration[] {
  const entries = readdirSync(dir).filter((f) => f.endsWith(".sql"));
  const migrations: Migration[] = [];
  for (const filename of entries) {
    const match = FILENAME_RE.exec(filename);
    if (!match) {
      throw new Error(
        `migration filename "${filename}" does not match NNNN_name.sql — please rename`,
      );
    }
    const seq = match[1];
    if (seq === undefined) continue;
    migrations.push({
      filename,
      sequence: Number.parseInt(seq, 10),
      sql: readFileSync(join(dir, filename), "utf8"),
    });
  }
  return sortAndValidate(migrations);
}

export function sortAndValidate(migrations: Migration[]): Migration[] {
  const sorted = [...migrations].sort((a, b) => a.sequence - b.sequence);
  for (let i = 1; i < sorted.length; i++) {
    const curr = sorted[i];
    const prev = sorted[i - 1];
    if (curr && prev && curr.sequence === prev.sequence) {
      throw new Error(
        `duplicate migration sequence ${curr.sequence}: ${prev.filename} and ${curr.filename}`,
      );
    }
  }
  return sorted;
}

const SCHEMA_VERSION_TABLE = `
CREATE TABLE IF NOT EXISTS schema_version (
  filename TEXT PRIMARY KEY,
  sequence INTEGER NOT NULL,
  applied_at INTEGER NOT NULL
);
`;

export function migrate(db: MigrationRunner, migrations: Migration[]): MigrationResult {
  db.exec(SCHEMA_VERSION_TABLE);

  const ordered = sortAndValidate(migrations);
  const appliedRows = db.prepare("SELECT filename FROM schema_version").all() as {
    filename: string;
  }[];
  const appliedSet = new Set(appliedRows.map((r) => r.filename));

  const applied: string[] = [];
  const skipped: string[] = [];

  const insert = db.prepare(
    "INSERT INTO schema_version (filename, sequence, applied_at) VALUES (?, ?, ?)",
  );

  for (const m of ordered) {
    if (appliedSet.has(m.filename)) {
      skipped.push(m.filename);
      continue;
    }
    db.transaction(() => {
      db.exec(m.sql);
      insert.run(m.filename, m.sequence, Date.now());
    })();
    applied.push(m.filename);
  }

  const currentVersion = ordered[ordered.length - 1]?.sequence ?? 0;
  return { applied, skipped, currentVersion };
}

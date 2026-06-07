// SQLite shim: wraps bun:sqlite with a better-sqlite3-compatible API so the
// CLI compiles to a single static binary via `bun build --compile` without
// requiring a native .node addon at runtime.
//
// Only the subset of the better-sqlite3 API used by this CLI is implemented:
//   new Database(path)
//   db.pragma(text)                → db.run("PRAGMA " + text)
//   db.exec(sql)
//   db.prepare(sql)                → { run, get, all }
//   db.transaction(fn)             → (...args) => fn(...args)  (synchronous)
//   db.close()

// Type-only import for bun:sqlite — suppressed via tsconfig when running
// under tsc (which doesn't know about bun globals). Bun itself resolves it.
// @ts-ignore bun:sqlite is only available inside the Bun runtime
import { Database as BunDatabase } from "bun:sqlite";
// biome-ignore lint/suspicious/noExplicitAny: bun:sqlite statement type varies
type AnyStatement = any;

export interface PreparedStatement {
  run(...params: unknown[]): unknown;
  get(...params: unknown[]): unknown;
  all(...params: unknown[]): unknown[];
}

export interface DbLike {
  pragma(text: string): void;
  exec(sql: string): void;
  prepare(sql: string): PreparedStatement;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  transaction<T extends unknown[], R>(fn: (...args: T) => R): (...args: T) => R;
  close(): void;
}

class BunStatement implements PreparedStatement {
  constructor(private readonly stmt: AnyStatement) {}

  run(...params: unknown[]): unknown {
    return this.stmt.run(...params);
  }

  get(...params: unknown[]): unknown {
    return this.stmt.get(...params);
  }

  all(...params: unknown[]): unknown[] {
    // biome-ignore lint/suspicious/noExplicitAny: runtime result shape unknown
    return this.stmt.all(...params) as unknown[];
  }
}

class BunDb implements DbLike {
  // biome-ignore lint/suspicious/noExplicitAny: BunDatabase type from ambient module
  private readonly db: any;

  constructor(path: string) {
    this.db = new BunDatabase(path);
  }

  pragma(text: string): void {
    this.db.run(`PRAGMA ${text}`);
  }

  exec(sql: string): void {
    this.db.exec(sql);
  }

  prepare(sql: string): PreparedStatement {
    return new BunStatement(this.db.prepare(sql));
  }

  transaction<T extends unknown[], R>(fn: (...args: T) => R): (...args: T) => R {
    return (...args: T): R => {
      const txn = this.db.transaction(fn);
      return txn(...args) as R;
    };
  }

  close(): void {
    this.db.close();
  }
}

// Callable both as `new Database(path)` and `Database(path)`.
export interface DatabaseConstructor {
  new (path: string): DbLike;
  (path: string): DbLike;
  // Namespace alias so `Database.Database` type references still resolve.
  Database: typeof BunDb;
}

function Database(path: string): DbLike {
  return new BunDb(path);
}
Database.Database = BunDb;

export default Database as unknown as DatabaseConstructor;

import { existsSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { migrate } from "@brandnana/schema";
import Database from "../sqlite.js";
import type { Command } from "commander";
import { bundledMigrations } from "../migrations.js";
import { emit, runAction } from "../output.js";

export function registerInit(program: Command) {
  program
    .command("init")
    .description("Initialize an .brandnana/ workspace with a fresh SQLite DB")
    .option("--db <path>", "SQLite path", ".brandnana/brandnana.sqlite")
    .action((opts: { db: string }) =>
      runAction(async () => {
        const dbPath = resolve(process.cwd(), opts.db);
        const dir = dirname(dbPath);
        if (!existsSync(dir)) {
          mkdirSync(dir, { recursive: true });
        }

        const db = new Database(dbPath);
        db.pragma("journal_mode = WAL");
        db.pragma("foreign_keys = ON");
        try {
          const result = migrate(db, bundledMigrations);
          const summaryLines = [
            `brandnana workspace ready at ${dbPath}`,
            `schema version: ${result.currentVersion}`,
          ];
          if (result.applied.length > 0) {
            summaryLines.push(`applied: ${result.applied.join(", ")}`);
          }
          if (result.skipped.length > 0) {
            summaryLines.push(`already applied: ${result.skipped.length} migration(s)`);
          }
          emit({ db: dbPath, ...result }, summaryLines.join("\n"));
        } finally {
          db.close();
        }
      }),
    );
}

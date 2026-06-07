// Inline migration SQL so the CLI bundle is self-contained.
// Bun supports `with { type: "text" }` import attributes; node 22+ does too
// when run via tsx/bun-built bundles. Keep this list in lockstep with
// packages/schema/migrations/.
import type { Migration } from "@brandnana/schema";
import sql0001 from "@brandnana/schema/migrations/0001_init.sql" with { type: "text" };

export const bundledMigrations: Migration[] = [
  { filename: "0001_init.sql", sequence: 1, sql: sql0001 },
];

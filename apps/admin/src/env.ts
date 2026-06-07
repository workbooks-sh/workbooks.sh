// Bindings type for the brandnana-admin Worker.
// Matches the [[d1_databases]], [[r2_buckets]], and secret declarations in wrangler.toml.

export interface Bindings {
  DB: D1Database;
  ASSETS: R2Bucket;
  BRANDNANA_ADMIN_KEY: string;
}

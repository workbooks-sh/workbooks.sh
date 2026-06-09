#!/usr/bin/env node
// Thin launcher: exec the native `wb` binary fetched by install.js.
const { spawnSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const bin = path.join(__dirname, process.platform === "win32" ? "wb.exe" : "wb");

if (!fs.existsSync(bin)) {
  console.error("[wb] native binary missing — re-run `npm rebuild @work.books/cli`,");
  console.error("[wb] or install directly:  curl -fsSL https://workbooks.sh/cli.sh | sh");
  process.exit(1);
}

const r = spawnSync(bin, process.argv.slice(2), { stdio: "inherit" });
if (r.error) {
  console.error(`[wb] ${r.error.message}`);
  process.exit(1);
}
process.exit(r.status === null ? 1 : r.status);

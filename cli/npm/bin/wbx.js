#!/usr/bin/env node
// Thin launcher: exec the native `work` binary fetched by install.js.
const { spawnSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const bin = path.join(__dirname, process.platform === "win32" ? "work.exe" : "work");

function fatal(reason) {
  process.stderr.write(
    "\n" +
    "╔══════════════════════════════════════════════════════════════╗\n" +
    "║  work is not installed correctly                               ║\n" +
    "╚══════════════════════════════════════════════════════════════╝\n" +
    `  ${reason}\n\n` +
    "  Fix options:\n" +
    "    1. Re-run the postinstall:  npm rebuild @work.books/cli\n" +
    "    2. Install via shell:       curl -fsSL https://workbooks.sh/cli.sh | sh\n\n"
  );
  process.exit(1);
}

// Check existence first, then executability (fs.accessSync X_OK).
if (!fs.existsSync(bin)) {
  fatal("Native binary not found — the postinstall download likely failed.");
}
try {
  fs.accessSync(bin, fs.constants.X_OK);
} catch (_) {
  fatal(`Binary exists but is not executable: ${bin}`);
}

const r = spawnSync(bin, process.argv.slice(2), { stdio: "inherit" });
if (r.error) {
  fatal(r.error.message);
}
process.exit(r.status === null ? 1 : r.status);

// postinstall: download the native `work` binary that matches this platform from
// the GitHub Release tagged `work-v<version>`, into ./bin/. One small launcher
// package per registry; the heavy binary comes from the Release (also the curl
// path). Set WB_CLI_SKIP_DOWNLOAD=1 to skip (e.g. in CI/sandboxes).
const fs = require("fs");
const path = require("path");
const https = require("https");

const REPO = process.env.WB_CLI_REPO || "workbooks-sh/workbooks.sh";
const { version } = require("./package.json");

function assetName() {
  const os = process.platform; // darwin | linux | win32
  const arch = process.arch; // arm64 | x64
  const a = arch === "arm64" ? "arm64" : arch === "x64" ? "x64" : arch;
  if (os === "darwin") return `work-darwin-${a}`;
  if (os === "linux") return `work-linux-${a}`;
  if (os === "win32") return `work-windows-${a}.exe`;
  throw new Error(`unsupported platform: ${os}/${arch}`);
}

// Resolve the first `work` on PATH that is NOT our just-installed binary.
// Returns the shadowing path string, or null if no shadow.
function findShadow(installedBin) {
  const resolved = path.resolve(installedBin);
  // Collect every directory on PATH and look for a work / work.exe match.
  const sep = process.platform === "win32" ? ";" : ":";
  const exeName = process.platform === "win32" ? "work.exe" : "work";
  const dirs = (process.env.PATH || "").split(sep).filter(Boolean);
  for (const dir of dirs) {
    const candidate = path.join(dir, exeName);
    try {
      const stat = fs.statSync(candidate);
      if (!stat.isFile()) continue;
      if (path.resolve(candidate) === resolved) return null; // it's ours — no shadow
      return candidate; // something else comes first
    } catch (_) {
      // not found in this dir
    }
  }
  return null;
}

function download(url, dest, redirects = 0) {
  return new Promise((resolve, reject) => {
    if (redirects > 10) return reject(new Error("too many redirects"));
    https
      .get(url, { headers: { "user-agent": "wb-cli-installer" } }, (res) => {
        if ([301, 302, 303, 307, 308].includes(res.statusCode)) {
          res.resume();
          return resolve(download(res.headers.location, dest, redirects + 1));
        }
        if (res.statusCode !== 200) {
          res.resume();
          return reject(new Error(`HTTP ${res.statusCode} for ${url}`));
        }
        const f = fs.createWriteStream(dest);
        res.pipe(f);
        f.on("finish", () => f.close(() => resolve()));
        f.on("error", reject);
      })
      .on("error", reject);
  });
}

async function main() {
  if (process.env.WB_CLI_SKIP_DOWNLOAD === "1") {
    console.log("[wb] skipping binary download (WB_CLI_SKIP_DOWNLOAD=1)");
    return;
  }
  const asset = assetName();
  const url = `https://github.com/${REPO}/releases/download/work-v${version}/${asset}`;
  const binDir = path.join(__dirname, "bin");
  fs.mkdirSync(binDir, { recursive: true });
  const out = path.join(binDir, process.platform === "win32" ? "work.exe" : "work");
  console.log(`[wb] downloading ${asset} (v${version})…`);
  await download(url, out);
  if (process.platform !== "win32") fs.chmodSync(out, 0o755);
  console.log("[wb] installed.");

  // FIX 1 — PATH-shadow check: warn if another work will shadow this install.
  const shadow = findShadow(out);
  if (shadow) {
    process.stderr.write(
      "\n" +
      "╔══════════════════════════════════════════════════════════════╗\n" +
      "║  work PATH SHADOW WARNING                                      ║\n" +
      "╚══════════════════════════════════════════════════════════════╝\n" +
      `  Another work binary was found earlier on your PATH:\n` +
      `    ${shadow}\n` +
      `  It will shadow the npm-installed wb. To fix, either:\n` +
      `    • Remove or rename the old binary:  rm ${shadow}\n` +
      `    • Or adjust PATH so npm's bin dir comes first.\n\n`
    );
  }
}

main().catch((e) => {
  // FIX 2 — LOUD failure banner so users aren't left with a silent broken install.
  const binOut = path.join(__dirname, "bin", process.platform === "win32" ? "work.exe" : "work");
  const alreadyPresent = (() => { try { return fs.statSync(binOut).isFile(); } catch (_) { return false; } })();

  process.stderr.write(
    "\n" +
    "╔══════════════════════════════════════════════════════════════╗\n" +
    "║  work install FAILED                                           ║\n" +
    "╚══════════════════════════════════════════════════════════════╝\n" +
    `  ${e.message}\n\n` +
    (alreadyPresent
      ? "  A previous binary is still present and may work.\n\n"
      : "  The work binary was NOT downloaded. Running `work` will fail.\n\n") +
    "  To install manually, run:\n" +
    "    curl -fsSL https://workbooks.sh/cli.sh | sh\n\n" +
    "  Or retry the download:\n" +
    "    npm rebuild @work.books/cli\n\n"
  );
  // Exit 0 to keep `npm install` non-fatal; the banner above is the signal.
  process.exit(0);
});

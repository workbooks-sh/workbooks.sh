// postinstall: download the native `wb` binary that matches this platform from
// the GitHub Release tagged `wb-v<version>`, into ./bin/. One small launcher
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
  if (os === "darwin") return `wb-darwin-${a}`;
  if (os === "linux") return `wb-linux-${a}`;
  if (os === "win32") return `wb-windows-${a}.exe`;
  throw new Error(`unsupported platform: ${os}/${arch}`);
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
  const url = `https://github.com/${REPO}/releases/download/wb-v${version}/${asset}`;
  const binDir = path.join(__dirname, "bin");
  fs.mkdirSync(binDir, { recursive: true });
  const out = path.join(binDir, process.platform === "win32" ? "wb.exe" : "wb");
  console.log(`[wb] downloading ${asset} (v${version})…`);
  await download(url, out);
  if (process.platform !== "win32") fs.chmodSync(out, 0o755);
  console.log("[wb] installed.");
}

main().catch((e) => {
  console.error(`[wb] install failed: ${e.message}`);
  console.error("[wb] you can also install via:  curl -fsSL https://workbooks.sh/cli.sh | sh");
  process.exit(0); // don't hard-fail the whole npm install; the shim re-checks
});

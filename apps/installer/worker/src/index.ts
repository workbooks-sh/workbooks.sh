import { Hono } from "hono";

const app = new Hono<{ Bindings: { BINARIES: R2Bucket } }>();

// GET / — serve the install script as plain text so `curl | sh` works
app.get("/", (c) =>
  new Response(INSTALL_SCRIPT, {
    headers: { "content-type": "text/plain; charset=utf-8" },
  })
);

// GET /binaries/:version/:name — stream a binary from R2
app.get("/binaries/:version/:name", async (c) => {
  const { version, name } = c.req.param();

  // Validate version and name to avoid path traversal
  if (!/^[a-zA-Z0-9._-]+$/.test(version) || !/^[a-zA-Z0-9._-]+$/.test(name)) {
    return c.text("invalid path", 400);
  }

  const key = `${version}/${name}`;
  const obj = await c.env.BINARIES.get(key);
  if (!obj) return c.text("not found", 404);

  return new Response(obj.body, {
    headers: {
      "content-type": "application/octet-stream",
      "content-disposition": `attachment; filename="${name}"`,
      etag: obj.httpEtag,
    },
  });
});

export default app;

// The install script is inlined here so the worker has zero external deps at
// runtime — no R2 read needed for the most common request path (GET /).
const INSTALL_SCRIPT = `#!/usr/bin/env sh
# brandnana installer — https://brandnana.net
set -eu

# Detect OS + arch
case "$(uname -s)" in
  Darwin) OS=darwin ;;
  Linux)  OS=linux  ;;
  *) echo "unsupported OS: $(uname -s)"; exit 1 ;;
esac
case "$(uname -m)" in
  arm64|aarch64) ARCH=arm64 ;;
  x86_64|amd64)  ARCH=x64   ;;
  *) echo "unsupported arch: $(uname -m)"; exit 1 ;;
esac

BINARY="brandnana-\${OS}-\${ARCH}"
VERSION="\${BRANDNANA_VERSION:-latest}"
URL="https://install.brandnana.net/binaries/\${VERSION}/\${BINARY}"
DEST="\${BRANDNANA_INSTALL_DIR:-\${HOME}/.local/bin}"

mkdir -p "\$DEST"
echo "[brandnana] fetching \$BINARY..."
curl -fL --progress-bar "\$URL" -o "\$DEST/brandnana"
chmod +x "\$DEST/brandnana"

# PATH check
case ":\$PATH:" in
  *":\$DEST:"*) ;;
  *) echo
     echo "  add \$DEST to your PATH:"
     echo "  echo 'export PATH=\\\$PATH:\$DEST' >> ~/.zshrc  # or ~/.bashrc"
     ;;
esac

echo
echo "[brandnana] installed: \$(\$DEST/brandnana --version 2>/dev/null || echo unknown)"
echo
echo "  next: brandnana auth login"
echo "  docs: https://brandnana.net"
`;

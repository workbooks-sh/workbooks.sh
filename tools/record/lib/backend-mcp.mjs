// MCP backend — drives the REAL Workbooks Browser (Tauri app) via its embedded
// MCP server (desktop/docs/mcp.md, wb-aakl.11/.23). Transport: AF_UNIX stream at
// /tmp/workbooks-mcp.sock (override WB_MCP_SOCK), newline-delimited JSON-RPC 2.0.
//
// This is the canonical app-tier seam: the intents map 1:1 onto the MCP toolset
// (screenshot / eval_js / dom_read / click / type / hover). No native browser
// automation outside the app — the host (Tauri) performs every action.
//
// NOTE: the JS-bridge round-trip (eval_js/dom_read/click/type) is wb-aakl.23,
// still ⏳ at time of writing. This backend is wired to the locked protocol; when
// .23 lands it works unchanged. `probe()` reports honestly whether the socket is
// live so the harness can fall back to the Playwright backend for web work.

import net from "node:net";
import fs from "node:fs/promises";
import path from "node:path";

const SOCK = process.env.WB_MCP_SOCK || "/tmp/workbooks-mcp.sock";

export class McpBackend {
  constructor({ outDir }) {
    this.outDir = outDir;
    this.sock = SOCK;
    this._id = 0;
    this._pending = new Map();
    this._buf = "";
    this.kind = "mcp";
  }

  async connect() {
    await new Promise((resolve, reject) => {
      this.conn = net.createConnection(this.sock);
      this.conn.setEncoding("utf8");
      this.conn.once("connect", resolve);
      this.conn.once("error", reject);
      this.conn.on("data", (d) => this._onData(d));
    });
    await this._rpc("initialize", {
      protocolVersion: "2024-11-05",
      capabilities: {},
      clientInfo: { name: "wb-record", version: "0.1.0" },
    });
    return this;
  }

  // Is the live browser's MCP socket reachable? (used for backend auto-select)
  static async probe() {
    try {
      await fs.access(SOCK);
    } catch {
      return { ok: false, reason: `socket ${SOCK} not present (is the browser running with WB_MCP=1?)` };
    }
    return await new Promise((resolve) => {
      const c = net.createConnection(SOCK);
      c.once("connect", () => {
        c.end();
        resolve({ ok: true });
      });
      c.once("error", (e) => resolve({ ok: false, reason: e.message }));
    });
  }

  _onData(chunk) {
    this._buf += chunk;
    let nl;
    while ((nl = this._buf.indexOf("\n")) >= 0) {
      const line = this._buf.slice(0, nl);
      this._buf = this._buf.slice(nl + 1);
      if (!line.trim()) continue;
      let msg;
      try {
        msg = JSON.parse(line);
      } catch {
        continue;
      }
      const p = this._pending.get(msg.id);
      if (!p) continue;
      this._pending.delete(msg.id);
      if (msg.error) p.reject(new Error(`MCP ${msg.error.code}: ${msg.error.message}`));
      else p.resolve(msg.result);
    }
  }

  _rpc(method, params) {
    const id = ++this._id;
    const payload = JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n";
    return new Promise((resolve, reject) => {
      this._pending.set(id, { resolve, reject });
      this.conn.write(payload);
      setTimeout(() => {
        if (this._pending.has(id)) {
          this._pending.delete(id);
          reject(new Error(`MCP rpc ${method} timed out`));
        }
      }, 30000);
    });
  }

  _call(tool, args = {}) {
    return this._rpc("tools/call", { name: tool, arguments: args });
  }

  // MCP result content -> first text block (tools return content[] of typed blocks)
  static _text(result) {
    const c = result?.content || [];
    const t = c.find((b) => b.type === "text");
    return t?.text ?? null;
  }
  static _image(result) {
    const c = result?.content || [];
    return c.find((b) => b.type === "image") || null;
  }

  async perform(step) {
    switch (step.intent) {
      case "navigate":
        // The app drives itself; closest native op is open_workbook by path.
        if (step.workbook) await this._call("open_workbook", { path: step.workbook });
        return {};
      case "click":
        await this._call("click", step.selector ? { selector: step.selector } : { x: step.x, y: step.y });
        return {};
      case "type":
        await this._call("type", { selector: step.selector, text: step.text });
        return {};
      case "hover":
        await this._call("hover", { selector: step.selector });
        return {};
      case "wait":
        await new Promise((r) => setTimeout(r, step.ms || 500));
        return {};
      case "eval_js": {
        const r = await this._call("eval_js", { code: step.code });
        return { value: McpBackend._text(r) };
      }
      case "dom_read": {
        const r = await this._call("dom_read", step.selector ? { selector: step.selector } : {});
        return { html: McpBackend._text(r) };
      }
      case "screenshot":
        return await this.screenshot(step.name);
      default:
        throw new Error(`mcp backend: unhandled intent ${step.intent}`);
    }
  }

  async screenshot(name = `shot-${Date.now()}`) {
    const r = await this._call("screenshot", {});
    const img = McpBackend._image(r);
    if (!img?.data) throw new Error("mcp screenshot: no image content returned");
    const file = path.join(this.outDir, `${name}.png`);
    await fs.writeFile(file, Buffer.from(img.data, "base64"));
    return { path: file };
  }

  // Console + DOM signals the verifier reads alongside the video. The app has no
  // CDP console feed, so we surface what the bridge can: window errors captured
  // by an injected hook (best-effort), plus the live outerHTML.
  async collectSignals() {
    let console = [];
    let html = null;
    try {
      const r = await this._call("eval_js", {
        code: "JSON.stringify((window.__WB_REC_ERRORS__||[]).slice(-50))",
      });
      console = JSON.parse(McpBackend._text(r) || "[]");
    } catch {}
    try {
      const r = await this._call("dom_read", {});
      html = McpBackend._text(r);
    } catch {}
    return { console, html };
  }

  async close() {
    try {
      this.conn?.end();
    } catch {}
  }
}

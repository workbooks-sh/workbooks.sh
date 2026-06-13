/* Node 'os' shim — pure-JS, no host caps. The sandbox is a single in-wasm "machine": stable, minimal
 * answers so packages that probe os.* keep working. No real host detail is exposed. */
"use strict";
module.exports = {
  EOL: "\n",
  platform: function () { return "wasi"; },
  arch: function () { return "wasm32"; },
  type: function () { return "WASI"; },
  release: function () { return "0.0.0"; },
  hostname: function () { return "sandbox"; },
  tmpdir: function () { return "/tmp"; },
  homedir: function () { return "/"; },
  endianness: function () { return "LE"; },
  cpus: function () { return [{ model: "wasm", speed: 0, times: { user: 0, nice: 0, sys: 0, idle: 0, irq: 0 } }]; },
  totalmem: function () { return 0; },
  freemem: function () { return 0; },
  uptime: function () { return 0; },
  loadavg: function () { return [0, 0, 0]; },
  networkInterfaces: function () { return {}; },
  userInfo: function () { return { username: "sandbox", uid: -1, gid: -1, shell: null, homedir: "/" }; },
  constants: { signals: {}, errno: {} }
};

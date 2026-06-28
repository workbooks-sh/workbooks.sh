require = globalThis.require; module = globalThis.module; exports = globalThis.exports;
process = globalThis.process; Buffer = globalThis.Buffer; global = globalThis;
setTimeout = globalThis.setTimeout; clearTimeout = globalThis.clearTimeout;
setInterval = globalThis.setInterval; clearInterval = globalThis.clearInterval;
queueMicrotask = globalThis.queueMicrotask || function(f){ Promise.resolve().then(f); };

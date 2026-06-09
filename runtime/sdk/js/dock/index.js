// Dock SDK (JS) — the jco-authored-component counterpart of the Rust `dock` crate
// (wb-pkh.9). Turns the Dock's stringly WIT imports into ergonomic calls so a JS
// component never hand-marshals JSON or hand-builds output strings.
//
// Two layers, mirroring the Rust SDK:
//   * Pure helpers (out/rows/page/parseMany/checkError) — no imports, run anywhere.
//   * bind(imports): cap wrappers (llm/vfs/browse/command/parallel) over the
//     jco-generated import functions. Cap-scoping is the imported WIT world (jco
//     componentize targets a world), so you only get the caps your world imports.
//
//   import { bind, out } from "dock";
//   const dock = bind(imports);                  // imports = your jco bindings
//   export function run(input) {
//     const reply = dock.llm.ask(`In 5 words: ${input}`);
//     return out({ asked: input, llm: reply });
//   }

/** A Dock call that failed host-side (the host returns `{"error": "..."}`). */
export class DockError extends Error {
  constructor(message) {
    super(message);
    this.name = "DockError";
  }
}

/** Build the `run` return string from any value — the clean replacement for
 * hand-rolled template-string JSON + quote escaping. */
export function out(value) {
  return JSON.stringify(value);
}

/** Throw DockError if `json` is a lone host error envelope `{"error": "..."}`. */
export function checkError(json) {
  let v;
  try {
    v = JSON.parse(json);
  } catch {
    return; // not JSON → not an error envelope; let the caller's parse decide
  }
  if (v && typeof v === "object" && !Array.isArray(v)) {
    const keys = Object.keys(v);
    if (keys.length === 1 && keys[0] === "error" && typeof v.error === "string") {
      throw new DockError(v.error);
    }
  }
}

/** Parse a Dock JSON string into rows (e.g. the result of vfs-query). Throws on a
 * host error envelope. */
export function rows(json) {
  checkError(json);
  return JSON.parse(json);
}

/** Parse a Dock JSON string into a page object (the result of browse-fetch). */
export function page(json) {
  checkError(json);
  return JSON.parse(json);
}

/** Parse the JSON array a run-command-many (parallel) call returns into per-worker
 * results, in order: each element is `{ ok: stdout }` or `{ error: reason }`. */
export function parseMany(json) {
  checkError(json);
  const arr = JSON.parse(json);
  if (!Array.isArray(arr)) throw new DockError("run-command-many: expected a JSON array");
  return arr.map((v) =>
    v && typeof v.ok === "string" ? { ok: v.ok } : { error: (v && v.error) ?? "unknown" }
  );
}

/** Wrap jco-generated import functions into ergonomic, cap-scoped helpers. Pass
 * the bindings your component imports; only the caps present resolve. */
export function bind(imports) {
  const has = (fn) => typeof imports?.[fn] === "function";
  const api = {};

  if (has("llmComplete")) {
    api.llm = {
      ask(prompt) {
        const r = imports.llmComplete(String(prompt));
        checkError(r);
        return r;
      },
    };
  }
  if (has("vfsQuery")) {
    api.vfs = {
      query(sql) {
        return rows(imports.vfsQuery(String(sql)));
      },
    };
  }
  if (has("browseFetch")) {
    api.browse = {
      fetch(url) {
        return page(imports.browseFetch(String(url)));
      },
    };
  }
  if (has("runCommand")) {
    api.command = {
      run(name, input, args = []) {
        const r = imports.runCommand(String(name), String(input), args.map(String));
        checkError(r);
        return r;
      },
    };
  }
  if (has("runCommandMany")) {
    api.parallel = {
      map(name, inputs) {
        return parseMany(imports.runCommandMany(String(name), JSON.stringify(inputs)));
      },
    };
  }
  return api;
}

# Browser SDK — toolkits drive the browser (wb-aakl.15)

The workbooks browser is itself extensible: a toolkit ships a UI, registers
it as a **dock panel**, and drives the browser through the Browser SDK. The
host stays primitives-only — it exposes seams; toolkits own behavior
(behavior-belongs-in-config-layer canon). This is the "software built in
workbooks" story applied to the browser's own surface.

## The membrane

A dock panel's UI runs in an **iframe** (the default trust rung for loaded
artifacts — sandboxed; DOM-mounted Svelte components are reserved for
trusted/first-party panels). It talks to the host over `postMessage`:

```
wb-sdk-call   toolkit → host   { id, method, args }
wb-sdk-reply  host → toolkit   { id, ok, result?, error? }
wb-sdk-event  host → toolkit   { event, payload }
wb-theme      host → toolkit   { tokens }          (theme inheritance)
wb-theme-ready toolkit → host                       (handshake)
```

Protocol source of truth: `src/lib/sdk/protocol.ts`. Host dispatcher:
`src/lib/sdk/browserSdk.ts`. Wiring: `DockHost.svelte`.

## 1. Theme (frozen contract)

A toolkit loading `/browser-sdk.js` gets theme inheritance for free: on
load it signals `wb-theme-ready`; the host replies with `wb-theme` tokens
and re-posts whenever the active theme changes. The SDK applies them to the
toolkit's own `:root` as `--<token>` CSS vars, so the panel matches the
browser without any work. (DOM-mounted panels inherit the vars natively.)

## 2. Browser state API

`window.workbooks.browser` (from `/browser-sdk.js`):

| Call | Returns |
|---|---|
| `tabs.list()` | `[{id, path, title}]` |
| `tabs.active()` | `{id, path, title}` or null |
| `tabs.open(path)` / `tabs.focus(id)` / `tabs.close(id)` | `{ok}` |
| `bookmarks.list()` | `[{id, title, path}]` |
| `bookmarks.add(title, path)` / `bookmarks.remove(id)` | `{ok}` |
| `workspace.active()` | `{id}` |
| `workspace.list()` | `[{id, name}]` |
| `package.active()` | `{name}` or null |
| `viewer.current()` | `{path, title}` of the focused doc, or null |
| `nexus.active()` | `{name, url, mode}` of the connected runtime |
| `theme.tokens()` | the current token map |

Every call returns a Promise. The surface is exactly what the user can do
in the UI — no raw fs/exec. `browser.call(method, args)` is a forward-compat
escape hatch.

## 3. Events

```js
browser.on("tab-changed",     (t) => { /* {id, path} | null */ });
browser.on("workbook-opened", (w) => { /* {path} */ });
browser.on("theme-changed",   (t) => { /* token map */ });
```

This is what makes "open a workbook → the dock toolkit reacts to it" (and a
thousand combinations like it) a one-liner.

## 4. Registration manifest

```ts
import { registerToolkitPanel } from "$lib/sdk/manifest";
import MyIcon from "...";

registerToolkitPanel({
  id: "my-toolkit",
  title: "My Toolkit",
  icon: MyIcon,
  entry: { iframeSrc: "https://nexus/toolkits/my-toolkit/panel.html" },
});
```

`{ id, title, icon, entry }` maps onto `dock.register`. The panel's icon
appears in the titlebar dock toolbar; clicking opens it in the right dock.
First-party panels may pass `entry: { component }` for a DOM-mounted Svelte
component instead of an iframe.

## 5. Write your own agent for the browser

An agent toolkit is just a dock panel that uses the SDK: read
`viewer.current()`, react to `workbook-opened`, call `tabs.open()`. That is
the recursive demo — the agent is software built in workbooks, summoned in
the dock; never a self-running site (pitch canon). Waldo (wb-aakl.21) is the
first-party instance of exactly this.

## Security

- iframe panels are sandboxed; the SDK is the only channel to the host.
- The method surface reuses existing UI commands, so a panel grants no
  capability the user lacks. No fs/exec/network beyond what the host
  already brokers.
- DOM-mounted components bypass the iframe boundary — reserved for
  first-party/trusted panels only.

## Status

- ✅ Theme contract, state API, events, manifest, client SDK
  (`static/browser-sdk.js`), host dispatcher + DockHost wiring.
- Future surfaces (left-nav contributions, palette commands) extend the
  same membrane — see wb-aakl.17.

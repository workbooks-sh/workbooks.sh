# Workbooks Desktop — product showcase

- TARGET: web
- URL: http://localhost:5178/
- FPS: 30
- VIEWPORT: 1440x900
- VERIFY_FRAMES: 16

> SILENT product cut — no voiceover, no audio. Tight hard cuts, short dwell,
> ~75-85s. The narration lines below are anchors for the VERIFIER only; the
> pipeline runs WITHOUT --voiceover, so the final MP4 is silent.
>
> Five scenes, hard cuts between them:
> 1. Four distinct brands — switch workspace + open each dashboard.
> 2. Multi-tab split into a 2x2 GRID — four brand dashboards, quadranted.
> 3. Drag a file from search into the sidebar Bookmarks group — it sticks.
> 4. REAL text chat (foreground) — a real Waldo run creates a workbook.
> 5. Voice — open the Waldo voice panel, drive a REAL agent turn, END cleanly.
>
> Cursor travel: every interaction uses click / rightclick / move / drag —
> native intents that move the visible cursor on a human arc to the target
> before acting. No eval_js teleports for anything the viewer sees clicked.

## Scene 1 — four distinct brands

## 00:00 navigate [url:http://localhost:5178/] [waitUntil:networkidle]

One window, every workspace you run.

## 00:02 click

Four real businesses live here — switch from one menu.

- selector: `button[aria-label^="Switch workspace"]`

## 00:03 click

First — Brand Nana, a brand-intelligence studio.

- selector: `button:has-text("Brand Nana")`

## 00:05 click

Open its live Brand Health board — cream and amber.

- selector: `button:has-text("Brand Health")`
- checkpoint: a warm cream-and-amber brand-health dashboard with charts is open in a tab

## 00:08 click

A totally different business — UGC Pro, a creator marketplace.

- selector: `button[aria-label^="Switch workspace"]`

## 00:09 click

- selector: `button:has-text("UGC Pro")`

## 00:11 click

Creator HQ — bold pink and magenta.

- selector: `button:has-text("Creator HQ")`
- checkpoint: a bold pink/magenta creator dashboard is open in a tab

## 00:14 click

A third — Parcel, a real-estate brokerage.

- selector: `button[aria-label^="Switch workspace"]`

## 00:15 click

- selector: `button:has-text("Parcel")`

## 00:17 click

Market Pulse — terracotta and warm neutrals.

- selector: `button:has-text("Market Pulse")`
- checkpoint: a terracotta real-estate market dashboard is open in a tab

## 00:20 click

And a fourth — Signal, an institutional treasury terminal.

- selector: `button[aria-label^="Switch workspace"]`

## 00:21 click

- selector: `button:has-text("Signal")`

## 00:23 click

Global Cash Position — dark, dense, institutional.

- selector: `button:has-text("Global Cash Position")`
- checkpoint: a fully dark institutional treasury dashboard is open in a tab

## 00:26 wait [ms:1400]

Four real brands, one window.

## Scene 2 — multi-tab split into a 2x2 GRID

> Four dashboards are now open as tabs. Right-click each of the last three tabs
> and Split right; at three-plus panes the layout auto-quadrants into a 2x2 grid.

## 00:28 rightclick

Right-click a tab — split the view.

- selector: `.tab:has-text("Global-cash-position")`

## 00:30 click

Split right — two brands side by side.

- selector: `button:has-text("Split right")`
- checkpoint: the view is split into two panes showing two different brand dashboards

## 00:32 rightclick

- selector: `.tab:has-text("Creator-hq")`

## 00:34 click

Again — three panes.

- selector: `button:has-text("Split right")`
- checkpoint: the view is split into three panes

## 00:36 rightclick

- selector: `.tab:has-text("Market-pulse")`

## 00:38 click

Four panes — every workspace at once, in a 2x2 grid.

- selector: `button:has-text("Split right")`
- checkpoint: the view is a 2x2 quadrant grid of four different brand dashboards (cream, dark, pink, terracotta)

## 00:40 wait [ms:1800]

Four brands, four panes, one window.

## Scene 3 — drag a file into Bookmarks

## 00:43 navigate [url:http://localhost:5178/] [waitUntil:networkidle]

Everything you've made is one keystroke away.

## 00:45 click

Open search.

- selector: `button[aria-label="Search"]`
- checkpoint: a search drawer is open showing a feed of file cards

## 00:47 wait [ms:1200]

Files, bookmarks, and the web — one search.

## 00:48 drag

Drag a file onto Bookmarks — and it sticks.

- selector: `.result[draggable="true"]`
- to: `[aria-label="Bookmarks"]`
- checkpoint: a file card is being dragged from the search drawer toward the sidebar Bookmarks group

## 00:51 wait [ms:1600]

And it sticks — pinned to your sidebar.

- checkpoint: a bookmark tile now sits in the sidebar Bookmarks group (the dashed empty placeholder is gone)

## 00:53 click

Close search — the bookmark stays pinned.

- selector: `button[aria-label="Search"]`

## 00:54 wait [ms:1500]

Pinned to your sidebar.

## Scene 4 — REAL text chat (foreground)

## 00:56 type [text:Create a workbook called Launch Plan with three sections: goals, timeline, risks.] [perKeyMs:42]

Just ask, in plain language.

- selector: `textarea[placeholder="What would you like to do?"]`

## 01:01 click

Send it — a real agent run starts.

- selector: `button.primary[type="submit"]`
- checkpoint: the create page has animated into a foreground chat thread — the user's message is a bubble at top, the composer has dropped to the bottom

## 01:03 eval_js

The page becomes the conversation. Waldo runs — real inference, real tool calls.

- code:

```js
(async () => { const deadline = Date.now() + 55000; const done = () => [...document.querySelectorAll('.status-line')].some(e => /Session complete/i.test(e.textContent || '')); while (Date.now() < deadline && !done()) { await new Promise(r => setTimeout(r, 300)); } const t = document.querySelector('.thread'); if (t) t.scrollTop = t.scrollHeight; const reply = [...document.querySelectorAll('.bubble.waldo')].find(b => !b.classList.contains('tool') && (b.textContent || '').trim().length > 20); return reply ? (reply.textContent || '').trim().slice(0, 200) : 'no-reply'; })()
```

- checkpoint: Waldo's reply is rendered, a vfs_write tool call is shown, and a "Session complete" line appears — a real, specific agent reply about the Launch Plan workbook

## 01:22 eval_js

A real workbook, built from a sentence.

- code:

```js
(() => { const t = document.querySelector('.thread'); if (t) t.scrollTop = t.scrollHeight; const reply = [...document.querySelectorAll('.bubble.waldo')].find(b => !b.classList.contains('tool') && (b.textContent || '').trim().length > 20); return reply ? (reply.textContent || '').trim().slice(0, 200) : 'no-reply'; })()
```

- checkpoint: the completed conversation is fully visible — the user prompt, Waldo's real reply about the Launch Plan workbook, the vfs_write tool call, and the Session complete line

## 01:25 wait [ms:2600]

A real workbook, built from a sentence.

## Scene 5 — voice

## 01:28 navigate [url:http://localhost:5178/] [waitUntil:networkidle]

And you can just talk to it.

## 01:30 click

Open the create menu.

- selector: `button.plus-btn`

## 01:31 click

Talk by voice.

- selector: `button.plus-item:has-text("Talk by voice")`
- checkpoint: the Waldo voice panel is opening on the right

## 01:33 eval_js

The voice panel opens with a Listening strip.

- code:

```js
(async () => { const deadline = Date.now() + 9000; const live = () => /Listening/i.test(document.querySelector('.voice-status')?.textContent || '') && typeof window.__wbVoiceInject === 'function'; while (Date.now() < deadline && !live()) { await new Promise(r => setTimeout(r, 200)); } return (document.querySelector('.voice-status')?.textContent || '').trim() + ' | inject:' + (typeof window.__wbVoiceInject); })()
```

- checkpoint: the Waldo voice panel shows an aurora-bordered Listening strip with a green dot, a mic button, and a red End button

## 01:37 eval_js

Ask it out loud — a real agent turn runs through the connected runtime.

- code:

```js
(() => { if (typeof window.__wbVoiceInject !== "function") return "no-hook"; window.__wbVoiceInject("What can you do in this browser?"); return "spoke"; })()
```

## 01:39 wait [ms:13000]

Waldo answers — hands-free, a real reply.

- checkpoint: the voice transcript shows a "You" bubble with the spoken question and a "Waldo" bubble with a real, specific reply listing what it can do

## 01:52 click

End the session cleanly.

- selector: `button[aria-label="End voice conversation"]`
- checkpoint: the voice session has ended and the composer (What would you like to do?) is back — not left hanging

## 01:54 wait [ms:2400]

Workbooks — every workspace, every agent, your whole team. One window.

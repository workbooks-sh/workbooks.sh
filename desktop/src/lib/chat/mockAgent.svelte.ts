// Browser-preview mock agent for the component-toolkit artifact flow.
//
// In the packaged app, `ws.sendUserInput()` POSTs `/api/agent/run` and the
// runtime streams telemetry over Phoenix. The browser preview (webHost
// mock) has neither a runtime nor a socket, so this module stands in: it
// scripts a believable agent run that exercises the component-toolkit EXEC
// shape end-to-end — produce a component artifact, write it (in-memory),
// emit the `component_artifact` event, and finish.
//
// The scripted events are pushed through `ws.emitLocal()` on the live
// `session:<id>` topic, so the existing `chatSession` projection renders
// them with zero special-casing. Iterating: a follow-up prompt that
// mentions the same artifact emits an "updated" artifact event so the user
// can keep working the component WITH the agent (the feature's whole point).

import { ws } from "$lib/bridge/ws.svelte";
import { componentArtifacts } from "./artifacts.svelte";

/** True only in the browser preview where webHost installed its mock. */
export function mockMode(): boolean {
  return (
    typeof window !== "undefined" &&
    (window as unknown as { __WB_DEV_MOCK__?: boolean }).__WB_DEV_MOCK__ === true
  );
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Stream a piece of content as `llm_delta` chunks (mirroring the real
 *  OpenRouter SSE wire protocol the runtime forwards), so the chat render
 *  path is exercised identically in mock + live. Chunks a few chars per
 *  tick with a small delay; the authoritative full text still arrives at
 *  the subsequent `llm_turn_stop`. */
async function streamContent(
  emit: (name: string, payload?: Record<string, unknown>) => void,
  content: string,
  chunk = 4,
  delay = 18,
): Promise<void> {
  for (let i = 0; i < content.length; i += chunk) {
    emit("llm_delta", { metadata: { content: content.slice(i, i + chunk) } });
    await sleep(delay);
  }
}

/** Stream the agent's reasoning as `agent_reasoning` deltas (the runtime forwards
 *  the model's reasoning tokens the same way). The chat folds these into the
 *  current turn's collapsible reasoning block. */
async function streamReasoning(
  emit: (name: string, payload?: Record<string, unknown>) => void,
  content: string,
  chunk = 6,
  delay = 12,
): Promise<void> {
  for (let i = 0; i < content.length; i += chunk) {
    emit("agent_reasoning", { metadata: { content: content.slice(i, i + chunk) } });
    await sleep(delay);
  }
}

/** Stable artifact path derived from the user's prompt — so a follow-up
 *  referencing the same thing updates the same component (and tab) instead
 *  of spawning a new one. */
function artifactPathFor(prompt: string): { path: string; title: string } {
  const slug =
    prompt
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "")
      .split("-")
      .slice(0, 4)
      .join("-") || "component";
  const title = slug
    .split("-")
    .map((w) => w.charAt(0).toUpperCase() + w.slice(1))
    .join(" ");
  return { path: `/mock/components/${slug}.html`, title };
}

/** A real, branded, self-contained component the agent "built". This is the
 *  kind of artifact a component-toolkit EXEC produces: a single HTML file
 *  that opens in a workbook tab. Dark-first, live-green accent. */
function componentHtml(title: string, prompt: string, revision: number): string {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="dark light">
<title>${title}</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body {
    margin: 0; min-height: 100vh;
    font: 15px/1.6 ui-sans-serif, system-ui, "Geist", sans-serif;
    color: #e8eaed; background: #0e1014;
    display: grid; place-items: center; padding: 32px;
    background-image:
      radial-gradient(circle at 20% 0%, rgba(63,224,129,.10), transparent 45%),
      radial-gradient(circle at 80% 100%, rgba(63,224,129,.06), transparent 40%);
  }
  .card {
    width: min(560px, 100%);
    border: 1px solid #23262e; border-radius: 16px;
    background: linear-gradient(180deg, #15181e, #111419);
    padding: 28px 30px; box-shadow: 0 20px 60px rgba(0,0,0,.5);
  }
  .tag {
    display: inline-flex; align-items: center; gap: 6px;
    padding: 4px 11px; border-radius: 999px;
    background: rgba(63,224,129,.12); color: #3fe081;
    font: 600 11px/1 ui-monospace, "Geist Mono", monospace;
    letter-spacing: .06em; text-transform: uppercase;
  }
  .tag::before { content: ""; width: 6px; height: 6px; border-radius: 50%; background: #3fe081; }
  h1 { font-size: 22px; margin: 16px 0 6px; letter-spacing: -.01em; }
  p.sub { margin: 0 0 22px; color: #9aa0aa; font-size: 13.5px; }
  .row { display: flex; gap: 10px; flex-wrap: wrap; margin-bottom: 18px; }
  .stat {
    flex: 1 1 120px; padding: 14px 16px; border: 1px solid #23262e;
    border-radius: 12px; background: #0f1217;
  }
  .stat .k { font: 600 10px/1 ui-monospace, monospace; text-transform: uppercase;
    letter-spacing: .08em; color: #6b7280; }
  .stat .v { font-size: 24px; font-weight: 650; margin-top: 6px; color: #3fe081; }
  .actions { display: flex; gap: 10px; }
  button {
    flex: 1; padding: 11px 14px; border: 0; border-radius: 10px; cursor: pointer;
    font: 600 14px/1 inherit; transition: transform .08s, filter .12s;
  }
  button:active { transform: translateY(1px); }
  .primary { background: #3fe081; color: #06140c; }
  .primary:hover { filter: brightness(1.07); }
  .ghost { background: #1a1e25; color: #e8eaed; border: 1px solid #2a2e37; }
  .ghost:hover { background: #21262f; }
  .count { text-align: center; margin-top: 18px; font-size: 13px; color: #9aa0aa; }
  .count b { color: #3fe081; font-variant-numeric: tabular-nums; }
  .rev { margin-top: 20px; font: 11px/1.4 ui-monospace, monospace; color: #5b616b; }
</style></head>
<body>
  <main class="card">
    <span class="tag">Component artifact</span>
    <h1>${title}</h1>
    <p class="sub">Generated by the component-toolkit from: “${prompt.replace(/"/g, "&quot;")}”</p>
    <div class="row">
      <div class="stat"><div class="k">Status</div><div class="v">Live</div></div>
      <div class="stat"><div class="k">Revision</div><div class="v">${revision}</div></div>
    </div>
    <div class="actions">
      <button class="primary" id="inc">Increment</button>
      <button class="ghost" id="reset">Reset</button>
    </div>
    <p class="count">Interactions: <b id="n">0</b></p>
    <p class="rev">artifact · rev ${revision} · keep iterating with the agent →</p>
  </main>
  <script>
    let n = 0;
    const el = document.getElementById('n');
    document.getElementById('inc').onclick = () => { el.textContent = ++n; };
    document.getElementById('reset').onclick = () => { n = 0; el.textContent = 0; };
  </script>
</body></html>`;
}

/** Real, self-contained apps the scripted Waldo "builds" for recognized
 *  requests — so the browser-preview create flow renders an ACTUAL app (not a
 *  generic counter card) for the showcase. Unmatched prompts fall back to the
 *  generic component card. Each html is a single-file workbook that animates on
 *  load so the just-built app reads as alive on camera. */
const DEMO_BUILDS: { match: RegExp; title: string; html: string }[] = [
  {
    match: /habit|streak|routine|daily/i,
    title: "Habit Tracker",
    html: `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Habit Tracker</title><style>
:root{color-scheme:light}*{box-sizing:border-box}body{margin:0;font:14px/1.5 ui-sans-serif,system-ui,-apple-system,sans-serif;color:#14161a;background:#f6f7f9;padding:22px}
.head{display:flex;align-items:center;justify-content:space-between;margin-bottom:18px}
.head h1{margin:0;font-size:19px;letter-spacing:-.01em}.head .wk{color:#6b7280;font-size:12px}
.summary{display:flex;align-items:center;gap:14px;background:#fff;border:1px solid #e8eaee;border-radius:14px;padding:14px 18px;margin-bottom:16px}
.ring{--p:0;width:48px;height:48px;border-radius:50%;background:conic-gradient(#12a150 calc(var(--p)*1%),#eef0f3 0);display:grid;place-items:center;transition:--p .9s ease}
.ring::after{content:"";width:38px;height:38px;border-radius:50%;background:#fff}.ring b{position:absolute;font:600 12px/1 ui-monospace,monospace;color:#12a150}
.summary .lbl{font-weight:600}.summary .sub{color:#6b7280;font-size:12px}
table{width:100%;border-collapse:collapse;background:#fff;border:1px solid #e8eaee;border-radius:14px;overflow:hidden}
th,td{padding:0;text-align:center}thead th{font:600 11px/1 ui-sans-serif;color:#6b7280;text-transform:uppercase;letter-spacing:.05em;padding:12px 0}
thead th:first-child{text-align:left;padding-left:18px}tbody td:first-child{text-align:left;padding-left:18px;font-weight:600}
tbody tr{border-top:1px solid #eef0f3}tbody td{height:52px}
.cell{width:26px;height:26px;border-radius:50%;border:2px solid #dfe2e7;margin:0 auto;display:grid;place-items:center;cursor:pointer;transition:.18s}
.cell.on{background:#12a150;border-color:#12a150;transform:scale(1)}
.cell svg{width:14px;height:14px;color:#fff;opacity:0;transform:scale(.4);transition:.18s}.cell.on svg{opacity:1;transform:scale(1)}
.streak{font:600 12px/1 ui-monospace,monospace;color:#12a150}.streak span{color:#9aa0aa}
</style></head><body>
<div class="head"><h1>Habit Tracker</h1><span class="wk">This week · Jun 16 – 22</span></div>
<div class="summary"><div class="ring" id="ring"><b id="ringt">0%</b></div><div><div class="lbl" id="cnt">0 of 35 done</div><div class="sub">Keep the streak alive — tap a day to check it off.</div></div></div>
<table><thead><tr><th>Habit</th><th>M</th><th>T</th><th>W</th><th>T</th><th>F</th><th>S</th><th>S</th><th>Streak</th></tr></thead><tbody id="body"></tbody></table>
<script>
const HABITS=[["Drink water",[1,1,1,1,1,0,0]],["Read 20 min",[1,1,0,1,1,1,0]],["Workout",[1,0,1,0,1,0,0]],["Inbox zero",[1,1,1,1,0,0,0]],["Sleep by 11",[0,1,1,1,1,1,0]]];
const CHK='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg>';
const body=document.getElementById('body');const cells=[];
HABITS.forEach(([name,days])=>{const tr=document.createElement('tr');let html='<td>'+name+'</td>';days.forEach(()=>html+='<td></td>');let run=0,s=0;days.forEach(v=>{run=v?run+1:0;if(run>s)s=run});html+='<td><span class="streak">'+s+'<span> d</span></span></td>';tr.innerHTML=html;
days.forEach((v,i)=>{const c=document.createElement('div');c.className='cell';c.innerHTML=CHK;c.onclick=()=>{c.classList.toggle('on');recount()};tr.children[i+1].appendChild(c);cells.push([c,v])});body.appendChild(tr)});
function recount(){const on=document.querySelectorAll('.cell.on').length;const pct=Math.round(on/35*100);document.getElementById('cnt').textContent=on+' of 35 done';document.getElementById('ring').style.setProperty('--p',pct);document.getElementById('ringt').textContent=pct+'%'}
// animate the pre-set checks filling in on load
let i=0;const seed=cells.filter(([,v])=>v);(function tick(){if(i<seed.length){seed[i][0].classList.add('on');i++;recount();setTimeout(tick,55)}})();
</script></body></html>`,
  },
];

/** Track how many times each artifact path has been produced this session
 *  so a follow-up reads as an "update" (rev N+1) rather than a new file. */
const revisions = new Map<string, number>();

/** Intent buckets the scripted Waldo recognizes. Discovered from the prompt
 *  so the browser preview answers REAL, compelling requests as Waldo would —
 *  create a workbook, share it, stand up an agent — not "list the files". */
type Intent = "create" | "share" | "agent" | "default";

function detectIntent(prompt: string): Intent {
  const p = prompt.toLowerCase();
  if (/\b(share|invite|send (it|this)|collaborat|org|team|with (someone|my))/i.test(p))
    return "share";
  if (/\b(set ?up|create|build|make|spin up).*\bagent\b|\bagent that\b/i.test(p))
    return "agent";
  if (/\b(create|make|build|new|set ?up|start).*\b(workbook|app|dashboard|tracker|page)/i.test(p))
    return "create";
  return "default";
}

/** Run the scripted Waldo agent for one prompt. Emits the same telemetry
 *  event shape the real runtime does, on `session:<id>`, so the chat surface
 *  renders it with zero special-casing. Branches on intent so the demo reads
 *  like a real Waldo result — and at least one branch renders a custom inline
 *  component (a `#+begin_src component …` block the renderer treats like a
 *  tool-call result). */
export async function runMockComponentAgent(
  sessionId: string,
  prompt: string,
): Promise<void> {
  const topic = `session:${sessionId}`;
  const emit = (name: string, payload: Record<string, unknown> = {}) =>
    ws.emitLocal(name, { session_id: sessionId, ...payload }, topic);

  emit("session_started", { agent: { name: "Waldo" } });
  await sleep(220);
  emit("llm_turn_start", { metadata: { provider: "openrouter", model: "waldo" } });
  await sleep(120);

  const intent = detectIntent(prompt);

  if (intent === "create") {
    // Reason, then create + write the workbook with real tool calls, open it,
    // and confirm in clean Markdown. A recognized request ("build a habit
    // tracker") yields a REAL app; anything else falls back to the demo card.
    const demo = DEMO_BUILDS.find((d) => d.match.test(prompt));
    const derived = artifactPathFor(prompt);
    const path = derived.path;
    const title = demo?.title ?? derived.title;
    const slug = title.replace(/\s+/g, "-").toLowerCase();
    const rev = (revisions.get(path) ?? 0) + 1;
    revisions.set(path, rev);
    const action = rev === 1 ? "created" : "updated";

    await streamReasoning(
      emit,
      `They want ${title.toLowerCase()}. I'll scaffold a single-file workbook, lay out the weekly grid, wire the streak counters, then open it as a tab so they can use it right away.`,
    );
    await sleep(160);

    emit("tool_call_start", {
      metadata: { tool_name: "workbook_create", tool_call_id: `tc-${rev}`, args: { title } },
    });
    await sleep(440);
    componentArtifacts.register(path, demo ? demo.html : componentHtml(title, prompt, rev));
    emit("tool_call_stop", {
      metadata: { tool_name: "workbook_create", tool_call_id: `tc-${rev}`, status: "ok", result_size: 1 },
    });
    await sleep(160);

    emit("tool_call_start", {
      metadata: { tool_name: "vfs_write", tool_call_id: `tw-${rev}`, args: { path: `${slug}.work` } },
    });
    await sleep(400);
    emit("tool_call_stop", {
      metadata: { tool_name: "vfs_write", tool_call_id: `tw-${rev}`, status: "ok", result_size: 1 },
    });
    await sleep(120);

    emit("component_artifact", { path, title, kind: "workbook", action });
    await sleep(180);

    const content =
      action === "created"
        ? `Done — I built **${title}** and opened it in a tab.\n\n` +
          `It's a single-file workbook: a weekly grid of five habits with live streak counts. ` +
          `Tap any day to check it off. Tell me what to change and I'll edit it in place.`
        : `Updated **${title}** (revision ${rev}). The tab reflects the latest version — keep iterating.`;
    await streamContent(emit, content);
    emit("llm_turn_stop", {
      metadata: { provider: "openrouter", model: "waldo", status: "ok", content },
    });
  } else if (intent === "share") {
    await streamReasoning(emit, `A sharing request — I'll confirm who gets access and at what role.`);
    await sleep(160);
    const content =
      `Yes — you can share this with anyone in your organization. ` +
      `I'd add **Ada Lovelace**, **Grace Hopper**, and **Alan Turing** as **Editors**. ` +
      `Say the word and I'll send the invites.`;
    await streamContent(emit, content);
    emit("llm_turn_stop", {
      metadata: { provider: "openrouter", model: "waldo", status: "ok", content },
    });
  } else if (intent === "agent") {
    await streamReasoning(emit, `They want a new agent — I'll create it, give it sensible toolkits, and pin it to the workspace.`);
    await sleep(160);
    emit("tool_call_start", {
      metadata: { tool_name: "agent_create", tool_call_id: "tc-agent", args: { slug: "summarizer" } },
    });
    await sleep(420);
    emit("tool_call_stop", {
      metadata: { tool_name: "agent_create", tool_call_id: "tc-agent", status: "ok", result_size: 1 },
    });
    await sleep(120);
    const content =
      `Set up — I created **summarizer** and pinned it to your workspace.\n\n` +
      `It inherits your default model and ships with the **workbooks-browser** and ` +
      `**library-search** toolkits. Open its tab to tweak the prompt or add tools.`;
    await streamContent(emit, content);
    emit("llm_turn_stop", {
      metadata: { provider: "openrouter", model: "waldo", status: "ok", content },
    });
  } else {
    await streamReasoning(emit, `A general question — I'll answer directly and point to the next useful action.`);
    await sleep(140);
    const content =
      `I'm **Waldo**, your assistant in here. I can build workbooks and apps, ` +
      `talk to your data, set up agents, and search everything — by voice or text. ` +
      `Try *"build a habit tracker"* or *"set me up an agent that summarizes my notes."*`;
    await streamContent(emit, content);
    emit("llm_turn_stop", {
      metadata: { provider: "openrouter", model: "waldo", status: "ok", content },
    });
  }

  await sleep(60);
  emit("session_completed", { result: { ok: true } });
}

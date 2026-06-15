// Agent-as-tab helpers (feat/agent-tab).
//
// An AgentDef editor opens as a browser TAB and is itself a workbook.
// Tabs are keyed by path; an agent's tab path is the `agent://<slug>`
// scheme so classifyKind routes it to AgentTabView. We resolve the
// slug out of the path on the rendering side.

import { tabs } from "./store.svelte";

/** Tab path for an agent slug. `__new__` is the create-new sentinel —
 *  a blank draft agent that the editor saves under a real slug. */
export function agentTabPath(slug: string): string {
  return `agent://${slug}`;
}

/** Slug encoded in an `agent://<slug>` tab path (null if not one). */
export function agentSlugFromPath(path: string): string | null {
  const m = path.match(/^agent:\/\/(.+)$/i);
  return m ? decodeURIComponent(m[1]) : null;
}

/** Open (or focus) the agent editor as a workbook tab. */
export async function openAgentTab(slug: string): Promise<void> {
  await tabs.open(agentTabPath(slug));
}

/** Open a fresh create-new agent tab. */
export async function openNewAgentTab(): Promise<void> {
  await tabs.open(agentTabPath("__new__"));
}

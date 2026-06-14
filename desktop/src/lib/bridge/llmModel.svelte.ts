// The user's chosen LLM model (wb-2s09). Stored locally for display and
// forwarded to the runtime as WB_LLM_MODEL (via the env-var store, which the
// desktop pushes to the engine on save/boot). llm.ex reads WB_LLM_MODEL, so the
// picked model drives Waldo chat + agent runs. Picked in onboarding AND settings.
import { envVars } from "$lib/bridge/env_vars.svelte";

const LS_KEY = "wb.llm.model";

// Default = MiniMax M3 (cheaper-but-better, the #1 recommendation).
export const DEFAULT_MODEL = "minimax/minimax-m3";

export function getLlmModel(): string {
  if (typeof localStorage === "undefined") return DEFAULT_MODEL;
  return localStorage.getItem(LS_KEY) || DEFAULT_MODEL;
}

/** Persist the choice (localStorage for the UI) and forward WB_LLM_MODEL to the
 *  runtime via the env-var store. Best-effort on the forward — offline it's a
 *  no-op and applies on the next push. */
export async function setLlmModel(modelId: string): Promise<void> {
  if (!modelId) return;
  try {
    localStorage.setItem(LS_KEY, modelId);
  } catch {
    /* non-fatal */
  }
  try {
    await envVars.refresh();
    const existing = envVars.vars.find((v) => v.name === "WB_LLM_MODEL");
    if (existing) await envVars.update(existing.id, modelId);
    else await envVars.create({ name: "WB_LLM_MODEL", value: modelId, scope: "user" });
  } catch (e) {
    console.warn("[llmModel] forward WB_LLM_MODEL failed", e);
  }
}

// Phase B — Planning Wizard control-plane client (RUNTIME caps).
//
// Onboarding "wizard" surface lives on the optional Elixir runtime
// tier, reached over the discovered daemon {url, token} via
// engineRequest(). All three routes are PENDING (the runtime doesn't
// expose them yet), so every call must degrade gracefully when the
// daemon is offline: engineRequest throws EngineApiError code
// "daemon_down" (status 0) — we catch that and return an empty list
// or an error-status WizardStep instead of letting it reach the UI.
//
// Schema map (LOCKED):
//   list wizards   GET  /api/wizards            (surface?)->{wizards[]}
//   start wizard   POST /api/wizard/start       (args)->WizardStep
//   answer wizard  POST /api/wizard/:session_id/answer (id,answers)->WizardStep
//
// Exported names (WizardApiError, listWizards, StartArgs, startWizard,
// answerWizard) are stable — the modal imports them. Only bodies +
// internal call names changed.

import { EngineApiError, engineRequest } from "$lib/engine-api/gen";
import type {
  AnswerMap,
  WizardDefinitionSummary,
  WizardStep,
} from "./types";

// One engine error class; alias keeps existing call sites
// (PaletteModal instanceof checks) stable.
export { EngineApiError as WizardApiError };

/** True when the failure is "daemon/sidecar isn't running". Tolerates the
 *  legacy "sidecar_down" code until gen.ts is renamed to "daemon_down". */
function isDaemonDown(e: unknown): boolean {
  return (
    e instanceof EngineApiError &&
    (e.code === "daemon_down" || e.code === "sidecar_down")
  );
}

export async function listWizards(
  surface?: string,
): Promise<WizardDefinitionSummary[]> {
  try {
    const body = await engineRequest<{ wizards?: WizardDefinitionSummary[] }>(
      "/api/wizards",
      { query: surface ? `?surface=${encodeURIComponent(surface)}` : "" },
    );
    return Array.isArray(body?.wizards) ? body.wizards : [];
  } catch (e) {
    // Daemon offline → no wizards available yet. Empty list, never throw.
    if (isDaemonDown(e)) return [];
    throw e;
  }
}

export interface StartArgs {
  wizard_id: string;
  workspace?: string | null;
  package?: string | null;
  brief_target?: string | null;
  /** Free-form context the user typed in the modal's compose phase
   *  before the agent ran. Forwarded to the daemon so the agent's
   *  first question batch is informed by what the user already said. */
  initial_input?: string;
}

export async function startWizard(args: StartArgs): Promise<WizardStep> {
  try {
    return readStep(await engineRequest("/api/wizard/start", { body: args }));
  } catch (e) {
    if (isDaemonDown(e)) return offlineStep();
    throw e;
  }
}

export async function answerWizard(
  sessionId: string,
  answers: AnswerMap,
): Promise<WizardStep> {
  try {
    return readStep(
      await engineRequest(
        `/api/wizard/${encodeURIComponent(sessionId)}/answer`,
        { body: { answers } },
      ),
    );
  } catch (e) {
    if (isDaemonDown(e)) return offlineStep();
    throw e;
  }
}

/** Graceful-offline WizardStep — the modal already renders status:"error"
 *  as a failure banner, so this degrades without throwing to the UI. */
function offlineStep(): WizardStep {
  return {
    status: "error",
    error: "daemon_down",
    message: "Agent server isn't running.",
  };
}

function readStep(body: unknown): WizardStep {
  const step = body as Partial<WizardStep> & { error?: string; message?: string };
  if (step && (step.status === "ask" || step.status === "done")) {
    return step as WizardStep;
  }
  if (step?.status === "error") {
    throw new EngineApiError(step.error ?? "unknown", step.message ?? "Wizard error.", 200);
  }
  throw new EngineApiError(
    "bad_response",
    `Unexpected response shape: ${JSON.stringify(body)}`,
    200,
  );
}

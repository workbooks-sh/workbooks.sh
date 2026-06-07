// wb-ne0o / wb-tx6h — Planning Wizard HTTP client.
//
// Thin wrappers over the wb-mdb9 Phoenix endpoints. Errors normalize
// to a WizardApiError so the modal renders a consistent failure UI.

import { EngineApiError, engineRequest } from "$lib/engine-api/gen";
import type {
  AnswerMap,
  WizardDefinitionSummary,
  WizardStep,
} from "./types";

// One engine error class, generated from the verb schema; alias keeps
// existing call sites (PaletteModal instanceof checks) stable.
export { EngineApiError as WizardApiError };

export async function listWizards(
  surface?: string,
): Promise<WizardDefinitionSummary[]> {
  const body = await engineRequest<{ wizards?: WizardDefinitionSummary[] }>(
    "/api/wizards",
    { query: surface ? `?surface=${encodeURIComponent(surface)}` : "" },
  );
  if (!Array.isArray(body?.wizards)) {
    throw new EngineApiError("list_failed", "Response was missing `wizards`.", 200);
  }
  return body.wizards;
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
  return readStep(await engineRequest("/api/wizard/start", { body: args }));
}

export async function answerWizard(
  sessionId: string,
  answers: AnswerMap,
): Promise<WizardStep> {
  return readStep(
    await engineRequest(
      `/api/wizard/${encodeURIComponent(sessionId)}/answer`,
      { body: { answers } },
    ),
  );
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

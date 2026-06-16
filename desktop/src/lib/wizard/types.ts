// wb-ne0o / wb-tx6h — Planning Wizard wire types.
//
// Mirrors the JSON the agent's WizardController emits. Single
// source of truth on the client side.

export type QuestionType =
  | "single_select"
  | "multi_select"
  | "text"
  | "textarea"
  | "number";

export interface QuestionOption {
  value: string;
  label: string;
}

export interface Question {
  id: string;
  label: string;
  type: QuestionType;
  options?: QuestionOption[];
  default?: string | number | string[];
  required?: boolean;
}

/** Possible answer shapes per question type. */
export type Answer = string | number | string[] | null;
export type AnswerMap = Record<string, Answer>;

export interface WizardDefinitionSummary {
  id: string;
  title: string;
  agent_slug: string;
  brief_location: "workspace" | "package" | "ask";
  surfaces: string[];
  initial_prompt: string;
}

/** /api/wizard/start + /api/wizard/:id/answer response. */
export type WizardStep =
  | {
      status: "ask";
      session_id: string;
      questions: Question[];
    }
  | {
      status: "done";
      session_id: string;
      brief_path: string;
      /** wb-lueb — wizard metadata for the follow-on chat session.
       *  The server populates these from the wizard definition so
       *  the modal can hand them to chatSession.send() + the chat
       *  header attachment chip. Optional because old wb-mdb9-era
       *  responses didn't include them. */
      wizard_id?: string;
      wizard_title?: string;
      agent_slug?: string;
      /** wb-b86r — optional :EXECUTE_PROMPT: override from the
       *  manifest. When present, the modal uses this template
       *  (with {brief_path} substituted) instead of the default. */
      execute_prompt?: string;
    }
  | {
      status: "error";
      error: string;
      message: string;
    };

/** Local UI state for the in-progress wizard. */
export interface WizardState {
  sessionId: string | null;
  questions: Question[];
  loading: boolean;
  donePath: string | null;
  lastError: { code: string; message: string } | null;
}

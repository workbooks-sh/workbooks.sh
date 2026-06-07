<script lang="ts">
  /**
   * PaletteModal — the AI command palette (wb-5hc0.2 shell + .3 + .4).
   *
   * Design quality bar: minimalist, inviting, distraction-free.
   * Single text input. One result area below. One affordance for the
   * future voice-brainstorm mode (waveform icon — wired under
   * wb-5hc0.6). Esc / click-outside / Enter-with-empty-input dismiss.
   * Cmd+/ from anywhere is a peer trigger (wired by the host).
   *
   * Two interaction modes by composer state at open time:
   * - Empty composer → "Ask the workspace…" — header prelude framing.
   * - Composer has draft → "Enhance your draft…" — rewrite framing.
   *
   * Submit hits POST /api/palette/ask. Engine returns either:
   * - mode: "answer" → render the text in the modal body, stay open.
   * - mode: "write"  → dismiss the modal, fire `onwrite(text)` so the
   *                    host can fill the composer + show an Undo chip
   *                    (wb-5hc0.5).
   */
  import { tick } from "svelte";
  import {
    Sparkles,
    ArrowUp,
    AlertCircle,
    CheckCircle2,
    Kanban,
    ListChecks,
    Bot,
    Package,
    Wand2,
    BookOpen,
    type Icon as LucideIcon,
  } from "@lucide/svelte";
  import { askPalette, type PaletteResult } from "./api";
  import {
    startWizard,
    answerWizard,
    WizardApiError,
  } from "$lib/wizard/api";
  import type {
    Answer,
    AnswerMap,
    Question,
    WizardStep,
  } from "$lib/wizard/types";
  import QuestionField from "$lib/wizard/QuestionField.svelte";
  import { chatSession } from "$lib/chat/session.svelte";
  import { chrome } from "$lib/ui/chrome.svelte";

  // Keep the chrome store's paletteOpen flag in sync so peer surfaces
  // (LiveBar, etc.) know to defer to us while we're up.
  $effect(() => {
    chrome.paletteOpen = open;
    return () => {
      if (chrome.paletteOpen) chrome.paletteOpen = false;
    };
  });

  /** Wizard run config. When non-null, the palette opens in wizard
   *  mode instead of the ask/enhance Q→A flow (wb-dj5r.2). The host
   *  passes the wizard's id + a display title; the palette runs the
   *  existing /api/wizard/start + /answer flow internally and emits
   *  questions inline as cards in the transcript. */
  export type WizardModeConfig = {
    id: string;
    title: string;
    /** Optional explicit package folder. When omitted the palette uses
     *  `workdir` for both workspace + package scope (matches what the
     *  start surface already passes through). */
    package?: string | null;
    /** Optional :KIND: ask brief target — most wizards don't need it. */
    briefTarget?: string | null;
  };

  let {
    open = false,
    composerText = "",
    workdir = null,
    wizardMode = null,
    onclose,
    onwrite,
    onwizardfinish,
  }: {
    open?: boolean;
    composerText?: string;
    workdir?: string | null;
    /** When set, the palette opens in wizard mode instead of ask mode
     *  (wb-dj5r.2). */
    wizardMode?: WizardModeConfig | null;
    onclose: () => void;
    /** Called when the engine fires the write_to_composer tool. The
     *  host should replace the composer's contents with `text` and
     *  surface an Undo chip pointing at the prior contents. Optional
     *  for wizard-only callsites that never enter ask/enhance mode. */
    onwrite?: (text: string) => void;
    /** Called once a wizard finishes and the brief has landed. The
     *  palette closes itself before this fires; the host can use the
     *  hook to refresh any dependent UI. */
    onwizardfinish?: (briefPath: string) => void;
  } = $props();

  let promptInput = $state("");
  let busy = $state(false);
  let answer = $state<string | null>(null);
  let error = $state<string | null>(null);
  let inputEl = $state<HTMLTextAreaElement | undefined>(undefined);
  let cardEl = $state<HTMLDivElement | undefined>(undefined);
  let scrollEl = $state<HTMLDivElement | undefined>(undefined);

  // ── Wizard mode (wb-dj5r.2) ──
  //
  // Three sub-phases distinguished by state, no explicit enum:
  //   • compose   — wizardMode set + wizardSessionId == null
  //                 (user types intake in the bar; submit calls startWizard)
  //   • questions — wizardSessionId set + wizardQuestions non-empty
  //                 (cards render inline; submit calls answerWizard)
  //   • done      — wizardBriefPath set
  //                 (transient — palette auto-launches follow-on + closes)
  let wizardSessionId = $state<string | null>(null);
  let wizardQuestions = $state<Question[]>([]);
  let wizardAnswers = $state<AnswerMap>({});
  let wizardBriefPath = $state<string | null>(null);
  /** Snapshot of the wizard config at open-time so toggling wizardMode
   *  mid-run doesn't tear state. */
  let activeWizard = $state<WizardModeConfig | null>(null);

  const inWizard = $derived(activeWizard !== null);
  const wizardPhase = $derived<"compose" | "questions" | "done">(
    wizardBriefPath
      ? "done"
      : wizardSessionId && wizardQuestions.length > 0
        ? "questions"
        : "compose",
  );

  function resetWizardState() {
    wizardSessionId = null;
    wizardQuestions = [];
    wizardAnswers = {};
    wizardBriefPath = null;
    activeWizard = null;
  }

  function seedAnswers(qs: Question[]): AnswerMap {
    const out: AnswerMap = {};
    for (const q of qs) {
      if (q.default !== undefined && q.default !== null) {
        out[q.id] = q.default as Answer;
      } else if (q.type === "multi_select") {
        out[q.id] = [];
      } else if (q.type === "number") {
        out[q.id] = null;
      } else {
        out[q.id] = "";
      }
    }
    return out;
  }

  /** Lucide icon for a wizard id, or null if there's no convention.
   *  Matches the same icons the start-surface chips use so the header
   *  reads as "the thing the chip launched, just opened." */
  const WIZARD_ICONS: Record<string, typeof LucideIcon> = {
    "create-board": Kanban,
    "create-task": ListChecks,
    "create-agent": Bot,
    "create-package": Package,
    "create-skill": Wand2,
    "create-workbook": BookOpen,
  };
  const wizardIcon = $derived<typeof LucideIcon | null>(
    activeWizard ? (WIZARD_ICONS[activeWizard.id] ?? null) : null,
  );

  const wizardRequiredUnanswered = $derived.by(() => {
    return wizardQuestions.some((q) => {
      if (q.required === false) return false;
      const v = wizardAnswers[q.id];
      if (q.type === "multi_select") {
        return !Array.isArray(v) || v.length === 0;
      }
      return v === null || v === undefined || v === "";
    });
  });

  // Reset state every time the modal opens — stale answer / error
  // from a prior invocation shouldn't bleed through.
  $effect(() => {
    if (open) {
      promptInput = "";
      answer = null;
      error = null;
      busy = false;
      // Capture wizardMode at open-time so the host can clear its prop
      // without yanking state out from under an in-flight run.
      if (wizardMode && !activeWizard) {
        activeWizard = wizardMode;
        wizardSessionId = null;
        wizardQuestions = [];
        wizardAnswers = {};
        wizardBriefPath = null;
      } else if (!wizardMode && activeWizard) {
        resetWizardState();
      }
      queueMicrotask(() => inputEl?.focus());
    }
    if (!open) {
      // Modal closing → clean wizard state so a re-open in ask mode
      // doesn't render the prior wizard's questions.
      resetWizardState();
    }
  });

  // Auto-scroll the wizard's question pane as new batches arrive.
  $effect(() => {
    void wizardQuestions.length;
    if (scrollEl) {
      queueMicrotask(() => {
        scrollEl!.scrollTop = scrollEl!.scrollHeight;
      });
    }
  });

  const isEnhanceMode = $derived(composerText.trim() !== "");

  async function submit() {
    if (busy) return;
    if (inWizard) {
      if (wizardPhase === "compose") {
        await submitWizardCompose();
      } else if (wizardPhase === "questions") {
        await submitWizardAnswers();
      }
      return;
    }

    const p = promptInput.trim();
    if (!p) return;

    busy = true;
    error = null;
    answer = null;

    try {
      const result: PaletteResult = await askPalette(p, {
        composerText,
        workdir,
      });

      if (result.mode === "write") {
        onwrite?.(result.text);
        onclose();
      } else {
        answer = result.text;
      }
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    } finally {
      busy = false;
    }
  }

  async function submitWizardCompose() {
    if (!activeWizard) return;
    busy = true;
    error = null;
    try {
      const step = await startWizard({
        wizard_id: activeWizard.id,
        workspace: workdir,
        package: activeWizard.package ?? workdir,
        brief_target: activeWizard.briefTarget ?? null,
        initial_input: promptInput.trim() || undefined,
      });
      handleWizardStep(step);
    } catch (e) {
      error = wizardErrorMessage(e);
    } finally {
      busy = false;
    }
  }

  async function submitWizardAnswers() {
    if (!wizardSessionId || wizardRequiredUnanswered) return;
    busy = true;
    error = null;
    try {
      const step = await answerWizard(wizardSessionId, wizardAnswers);
      handleWizardStep(step);
    } catch (e) {
      error = wizardErrorMessage(e);
    } finally {
      busy = false;
    }
  }

  function handleWizardStep(step: WizardStep) {
    if (step.status === "ask") {
      wizardSessionId = step.session_id;
      wizardQuestions = step.questions;
      wizardAnswers = seedAnswers(step.questions);
      // The compose textarea is now stale — clear so it doesn't bleed
      // into the questions UI.
      promptInput = "";
      void tick().then(() => {
        if (scrollEl) scrollEl.scrollTop = scrollEl.scrollHeight;
      });
    } else if (step.status === "done") {
      wizardSessionId = step.session_id;
      wizardBriefPath = step.brief_path;
      onwizardfinish?.(step.brief_path);
      void launchWizardFollowOn(step);
    }
  }

  function wizardErrorMessage(err: unknown): string {
    if (err instanceof WizardApiError) {
      return `${err.code}: ${err.message}`;
    }
    return err instanceof Error ? err.message : String(err);
  }

  function onWizardAnswerChange(id: string, value: Answer) {
    wizardAnswers = { ...wizardAnswers, [id]: value };
  }

  /** Once the wizard's brief lands on disk, close the palette and
   *  hand off to the chat panel: the executor agent (workhorse by
   *  default, overridable per wizard) reads the brief and produces
   *  the actual artifact. */
  async function launchWizardFollowOn(
    step: Extract<WizardStep, { status: "done" }>,
  ) {
    chrome.agentOpen = true;
    chatSession.init();
    const wid = step.wizard_id ?? activeWizard?.id ?? "";
    const wtitle = step.wizard_title ?? activeWizard?.title ?? wid;
    const prompt = step.execute_prompt
      ? step.execute_prompt
          .replaceAll("{brief_path}", step.brief_path)
          .replaceAll("{wizard_id}", wid)
          .replaceAll("{wizard_title}", wtitle)
      : `I just finished the **${wtitle}** planning wizard. The brief is at:\n\n  ${step.brief_path}\n\nRead it, then execute the plan it describes. Use your oql tools (read, write, set_property, add_child, transition_todo) to make the changes — the brief carries the specification in its \`* Spec\` / \`* Configuration\` section. Report when done.`;

    await chatSession.send(prompt, {
      agentSlug: step.agent_slug ?? null,
      attachments: [
        {
          kind: "brief",
          path: step.brief_path,
          wizardId: wid,
          label: wtitle,
        },
      ],
    });
    onclose();
  }

  function onKey(e: KeyboardEvent) {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      void submit();
    }
  }

  function onBackdropClick(e: MouseEvent) {
    if (!cardEl) return;
    const t = e.target as Node;
    if (!cardEl.contains(t)) {
      onclose();
    }
  }

  function onWindowKey(e: KeyboardEvent) {
    if (open && e.key === "Escape") {
      e.preventDefault();
      onclose();
    }
  }
</script>

<svelte:window onkeydown={onWindowKey} />

{#if open}
  <div
    class="backdrop"
    onmousedown={onBackdropClick}
    role="presentation"
  >
    <div
      class="palette"
      bind:this={cardEl}
      role="dialog"
      aria-label="Ask the workspace"
    >
      {#if inWizard}
        <!-- Wizard mode (wb-dj5r). One wrapping container holds the
             title row, the input or question rows, and any status —
             rows separated by a hairline, no floating sub-cards. -->
        <div class="wizard-shell" class:busy>
          <div class="wizard-head">
            {#if wizardIcon}
              {@const Icon = wizardIcon}
              <Icon size={13} strokeWidth={2} aria-hidden="true" />
            {/if}
            <span class="wizard-head-label">{activeWizard?.title ?? ""}</span>
          </div>

          {#if wizardPhase === "compose"}
            <div class="wizard-row wizard-input-row">
              <textarea
                bind:this={inputEl}
                bind:value={promptInput}
                onkeydown={onKey}
                placeholder="Tell the wizard what you want — a phrase or a paragraph."
                rows="2"
                spellcheck="false"
                disabled={busy}
                aria-label="Wizard intake"
              ></textarea>
              <button
                type="button"
                class="trailing-btn primary"
                onclick={submit}
                disabled={busy}
                aria-label="Start wizard"
                title="Continue (Enter)"
              >
                <ArrowUp size={14} strokeWidth={2.5} aria-hidden="true" />
              </button>
            </div>
          {/if}

          {#if busy}
            <div class="wizard-row wizard-status-row">
              <span class="dots" aria-hidden="true">
                <span></span><span></span><span></span>
              </span>
              <span class="muted">
                {wizardPhase === "compose" ? "Starting wizard…" : "Thinking…"}
              </span>
            </div>
          {/if}

          {#if wizardPhase === "questions" && !busy}
            <div class="wizard-row wizard-questions" bind:this={scrollEl}>
              {#each wizardQuestions as q (q.id)}
                <div class="question-card">
                  <QuestionField
                    question={q}
                    value={wizardAnswers[q.id] ?? null}
                    onchange={(v) => onWizardAnswerChange(q.id, v)}
                  />
                </div>
              {/each}
            </div>
            <div class="wizard-row wizard-actions">
              <button
                type="button"
                class="continue-btn"
                onclick={submit}
                disabled={busy || wizardRequiredUnanswered}
              >
                <span>{wizardRequiredUnanswered ? "Fill required fields" : "Continue"}</span>
                <ArrowUp size={13} strokeWidth={2.5} aria-hidden="true" />
              </button>
            </div>
          {/if}

          {#if wizardPhase === "done" && !busy}
            <div class="wizard-row wizard-done-row">
              <CheckCircle2 size={14} strokeWidth={2} aria-hidden="true" />
              <span>Brief saved. Opening the chat to execute…</span>
            </div>
          {/if}

          {#if error && !busy}
            <div class="wizard-row wizard-err-row">
              <AlertCircle size={12} strokeWidth={2} aria-hidden="true" />
              <span>{error}</span>
            </div>
          {/if}
        </div>

        {#if wizardPhase === "compose" && !busy && !error}
          <div class="footer">
            <span class="spacer"></span>
            <span class="kbd-hint"><kbd>↵</kbd> start</span>
            <span class="kbd-hint"><kbd>esc</kbd> cancel</span>
          </div>
        {/if}
      {:else}
        <!-- The palette IS the input. No nested card. Single visual
             unit with the search icon, the textarea, and the send
             button all inside one bordered surface — Spotlight /
             Raycast / Cursor ⌘K vibe. Voice lives in the home
             composer, not here (wb-nlts). -->
        <div class="bar" class:busy>
          <span class="leading" aria-hidden="true">
            <Sparkles size={15} strokeWidth={2} />
          </span>
          <textarea
            bind:this={inputEl}
            bind:value={promptInput}
            onkeydown={onKey}
            placeholder={isEnhanceMode
              ? "Ask about your draft, or how to make it better"
              : "Ask anything about your workspace"}
            rows="1"
            spellcheck="false"
            disabled={busy}
            aria-label="Palette prompt"
          ></textarea>
          <div class="trailing">
            <button
              type="button"
              class="trailing-btn primary"
              onclick={submit}
              disabled={busy || promptInput.trim() === ""}
              aria-label="Send"
              title="Send (Enter)"
            >
              <ArrowUp size={14} strokeWidth={2.5} aria-hidden="true" />
            </button>
          </div>
        </div>

        <!-- Footer: keyboard nudges only. The mode (asking vs
             enhancing) is already conveyed by the placeholder text
             inside the input, so we don't duplicate it here. -->
        {#if !busy && !answer && !error}
          <div class="footer">
            <span class="spacer"></span>
            <span class="kbd-hint"><kbd>↵</kbd> send</span>
            <span class="kbd-hint"><kbd>esc</kbd> close</span>
          </div>
        {/if}

        {#if busy}
          <div class="result">
            <span class="dots" aria-hidden="true">
              <span></span><span></span><span></span>
            </span>
            <span class="muted">Thinking…</span>
          </div>
        {/if}

        {#if answer && !busy}
          <div class="result answer" tabindex="-1">{answer}</div>
        {/if}

        {#if error && !busy}
          <div class="result err">
            <AlertCircle size={12} strokeWidth={2} aria-hidden="true" />
            <span>{error}</span>
          </div>
        {/if}
      {/if}
    </div>
  </div>
{/if}

<style>
  .backdrop {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.35);
    backdrop-filter: blur(2px);
    -webkit-backdrop-filter: blur(2px);
    z-index: 1200;
    display: flex;
    align-items: flex-start;
    justify-content: center;
    padding: 14vh 2rem 4rem;
  }

  /* The palette is one floating object — the input bar itself is
   * the visual anchor, and the result area (if present) appears
   * underneath sharing the same width. Looks like Spotlight: a tall,
   * wide bar with subtle elevation. */
  .palette {
    width: 100%;
    max-width: 620px;
    display: flex;
    flex-direction: column;
    gap: 0.35rem;
  }

  .bar {
    display: flex;
    align-items: center;
    gap: 0.65rem;
    padding: 0.55rem 0.6rem 0.55rem 0.95rem;
    background: var(--color-surface);
    border: 1px solid var(--color-border-strong);
    border-radius: 12px;
    box-shadow:
      0 1px 2px rgba(0, 0, 0, 0.05),
      0 12px 32px rgba(0, 0, 0, 0.18);
    transition: border-color 0.12s;
  }
  .bar:focus-within {
    border-color: var(--color-fg-muted);
  }
  .bar.busy {
    opacity: 0.85;
  }

  .leading {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    color: var(--color-fg-muted);
    flex-shrink: 0;
  }

  textarea {
    flex: 1 1 auto;
    background: transparent;
    border: 0;
    outline: 0;
    color: var(--color-fg);
    font-family: inherit;
    font-size: 0.95rem;
    line-height: 1.5;
    resize: none;
    padding: 0.2rem 0;
    min-height: 24px;
    max-height: 200px;
    /* Single-line feel: lets the textarea grow vertically as needed
     * but starts as one line, matching the Spotlight pattern. */
    field-sizing: content;
  }
  textarea::placeholder {
    color: var(--color-fg-subtle);
  }

  .trailing {
    display: inline-flex;
    align-items: center;
    gap: 0.25rem;
    flex-shrink: 0;
  }
  .trailing-btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 28px;
    height: 28px;
    border: 0;
    background: transparent;
    color: var(--color-fg-muted);
    border-radius: 7px;
    cursor: pointer;
    transition: background 0.1s, color 0.1s, opacity 0.1s;
  }
  .trailing-btn:hover:not(:disabled) {
    background: var(--color-surface-soft);
    color: var(--color-fg);
  }
  .trailing-btn:disabled {
    opacity: 0.35;
    cursor: default;
  }
  .trailing-btn.primary {
    background: var(--color-fg);
    color: var(--color-page);
  }
  .trailing-btn.primary:hover:not(:disabled) {
    opacity: 0.9;
  }
  .trailing-btn.primary:disabled {
    background: var(--color-surface-soft);
    color: var(--color-fg-subtle);
    opacity: 1;
  }
  /* Footer hint row — subtle, single line, doesn't compete with
   * the input. Disappears when a result is showing. */
  .footer {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    padding: 0 0.25rem;
    font-size: 0.7rem;
    color: var(--color-fg-subtle);
  }
  .footer .mode {
    text-transform: uppercase;
    letter-spacing: 0.07em;
    font-weight: 600;
    color: var(--color-fg-muted);
  }
  .footer .spacer { flex: 1 1 auto; }
  .kbd-hint {
    display: inline-flex;
    align-items: center;
    gap: 0.25rem;
  }
  .kbd-hint kbd {
    font-family: ui-monospace, SFMono-Regular, monospace;
    font-size: 0.65rem;
    padding: 0.05rem 0.3rem;
    border: 1px solid var(--color-border);
    border-radius: 4px;
    background: var(--color-surface);
    color: var(--color-fg-muted);
  }

  /* Result/answer/error blocks all share .result for spacing + the
   * second-card visual treatment underneath the input bar. */
  .result {
    padding: 0.75rem 0.85rem;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 10px;
    font-size: 0.88rem;
    line-height: 1.55;
    color: var(--color-fg);
    box-shadow: 0 4px 16px rgba(0, 0, 0, 0.08);
    display: flex;
    align-items: flex-start;
    gap: 0.45rem;
  }
  .result.answer {
    display: block;
    white-space: pre-wrap;
    max-height: 50vh;
    overflow-y: auto;
  }

  /* ── Wizard mode (wb-dj5r) ──
   *
   * One wrapping container. Header row carries a small type-icon +
   * label; subsequent rows are the input or the question batch; rows
   * are separated by hairlines, not floating sub-cards. Same shell
   * styling as the ask-mode .bar so the modal feels like one cohesive
   * surface across modes. */
  .wizard-shell {
    display: flex;
    flex-direction: column;
    background: var(--color-surface);
    border: 1px solid var(--color-border-strong);
    border-radius: 12px;
    box-shadow:
      0 1px 2px rgba(0, 0, 0, 0.05),
      0 12px 32px rgba(0, 0, 0, 0.18);
    overflow: hidden;
  }
  .wizard-shell.busy { opacity: 0.92; }

  .wizard-head {
    display: flex;
    align-items: center;
    gap: 0.42rem;
    padding: 0.42rem 0.85rem;
    border-bottom: 1px solid var(--color-border);
    font-size: 0.72rem;
    font-weight: 600;
    letter-spacing: 0.015em;
    color: var(--color-fg-muted);
    background: var(--color-surface-soft);
  }
  .wizard-head-label {
    line-height: 1.3;
  }

  .wizard-row {
    padding: 0.55rem 0.85rem;
  }
  .wizard-row + .wizard-row {
    border-top: 1px solid var(--color-border);
  }

  .wizard-input-row {
    display: flex;
    align-items: center;
    gap: 0.6rem;
    padding: 0.55rem 0.55rem 0.55rem 0.85rem;
  }
  .wizard-input-row textarea {
    flex: 1 1 auto;
    background: transparent;
    border: 0;
    outline: 0;
    color: var(--color-fg);
    font-family: inherit;
    font-size: 0.95rem;
    line-height: 1.5;
    resize: none;
    padding: 0.2rem 0;
    min-height: 24px;
    max-height: 200px;
    field-sizing: content;
  }
  .wizard-input-row textarea::placeholder {
    color: var(--color-fg-subtle);
  }

  .wizard-status-row,
  .wizard-done-row,
  .wizard-err-row {
    display: flex;
    align-items: center;
    gap: 0.45rem;
    font-size: 0.85rem;
  }
  .wizard-done-row { color: #10b981; }
  .wizard-err-row {
    color: #ef4444;
    background: color-mix(in srgb, #ef4444 6%, var(--color-surface));
    font-size: 0.82rem;
  }

  .wizard-questions {
    display: flex;
    flex-direction: column;
    gap: 0.65rem;
    max-height: 55vh;
    overflow-y: auto;
    padding: 0.7rem 0.85rem;
  }
  .question-card {
    /* Borderless — the container already provides the frame. */
    padding: 0;
  }

  .wizard-actions {
    display: flex;
    justify-content: flex-end;
    padding: 0.45rem 0.55rem;
  }
  .continue-btn {
    display: inline-flex;
    align-items: center;
    gap: 0.4rem;
    height: 30px;
    padding: 0 0.85rem;
    border: 0;
    border-radius: 7px;
    background: var(--color-fg);
    color: var(--color-page);
    font: inherit;
    font-size: 0.82rem;
    font-weight: 600;
    cursor: pointer;
    transition: opacity 0.1s;
  }
  .continue-btn:hover:not(:disabled) { opacity: 0.9; }
  .continue-btn:disabled {
    background: var(--color-surface-soft);
    color: var(--color-fg-subtle);
    cursor: default;
  }
  .result.err {
    color: #ef4444;
    background: color-mix(in srgb, #ef4444 8%, var(--color-surface));
    border-color: color-mix(in srgb, #ef4444 30%, var(--color-border));
    font-size: 0.82rem;
  }

  .muted {
    color: var(--color-fg-muted);
    font-size: 0.85rem;
  }

  /* Three-dot thinking indicator — same affordance Spotlight uses
   * during slow lookups. Lighter touch than a spinner. */
  .dots {
    display: inline-flex;
    align-items: center;
    gap: 3px;
    margin-top: 0.45rem;
  }
  .dots span {
    width: 4px;
    height: 4px;
    border-radius: 50%;
    background: var(--color-fg-muted);
    animation: dot 1.1s ease-in-out infinite;
  }
  .dots span:nth-child(2) { animation-delay: 0.18s; }
  .dots span:nth-child(3) { animation-delay: 0.36s; }
  @keyframes dot {
    0%, 80%, 100% { opacity: 0.25; transform: translateY(0); }
    40% { opacity: 1; transform: translateY(-2px); }
  }
</style>

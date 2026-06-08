<script lang="ts">
  /**
   * wb-ne0o / wb-tx6h — single wizard-question renderer. Used inline
   * by the palette modal's wizard mode (wb-dj5r).
   *
   * Branches by question type. Bindings flow through `value` (callback)
   * so the parent can keep a flat AnswerMap.
   */
  import type { Answer, Question } from "./types";

  let {
    question,
    value,
    onchange,
  }: {
    question: Question;
    value: Answer;
    onchange: (next: Answer) => void;
  } = $props();

  function toggleMulti(option: string, checked: boolean) {
    const current = Array.isArray(value) ? [...value] : [];
    const idx = current.indexOf(option);
    if (checked && idx === -1) {
      current.push(option);
    } else if (!checked && idx !== -1) {
      current.splice(idx, 1);
    }
    onchange(current);
  }

  const multiSelected = $derived<string[]>(
    Array.isArray(value) ? value : [],
  );
</script>

<div class="field">
  <label class="label" for={`field-${question.id}`}>
    {question.label}
    {#if question.required !== false}
      <span class="required" aria-hidden="true">*</span>
    {/if}
  </label>

  {#if question.type === "single_select"}
    <div class="options" role="radiogroup" aria-labelledby={`field-${question.id}`}>
      {#each question.options ?? [] as opt (opt.value)}
        <label class="option" class:selected={value === opt.value}>
          <input
            type="radio"
            name={question.id}
            value={opt.value}
            checked={value === opt.value}
            onchange={() => onchange(opt.value)}
          />
          <span>{opt.label}</span>
        </label>
      {/each}
    </div>
  {:else if question.type === "multi_select"}
    <div class="options" role="group" aria-labelledby={`field-${question.id}`}>
      {#each question.options ?? [] as opt (opt.value)}
        <label
          class="option"
          class:selected={multiSelected.includes(opt.value)}
        >
          <input
            type="checkbox"
            checked={multiSelected.includes(opt.value)}
            onchange={(e) =>
              toggleMulti(opt.value, (e.target as HTMLInputElement).checked)}
          />
          <span>{opt.label}</span>
        </label>
      {/each}
    </div>
  {:else if question.type === "textarea"}
    <textarea
      id={`field-${question.id}`}
      rows="4"
      value={typeof value === "string" ? value : ""}
      oninput={(e) => onchange((e.target as HTMLTextAreaElement).value)}
    ></textarea>
  {:else if question.type === "number"}
    <input
      id={`field-${question.id}`}
      type="number"
      value={typeof value === "number" || typeof value === "string" ? value : ""}
      oninput={(e) => {
        const raw = (e.target as HTMLInputElement).value;
        if (raw === "") onchange(null);
        else {
          const n = Number(raw);
          onchange(isNaN(n) ? raw : n);
        }
      }}
    />
  {:else}
    <input
      id={`field-${question.id}`}
      type="text"
      value={typeof value === "string" ? value : ""}
      oninput={(e) => onchange((e.target as HTMLInputElement).value)}
    />
  {/if}
</div>

<style>
  .field {
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
  }
  .label {
    font-size: 13px;
    font-weight: 500;
    color: var(--color-fg);
    line-height: 1.4;
  }
  .required {
    color: var(--color-fg-muted);
    margin-left: 0.125rem;
  }
  .options {
    display: flex;
    flex-direction: column;
    gap: 0.25rem;
  }
  .option {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    padding: 0.5rem 0.625rem;
    border: 1px solid var(--color-border);
    border-radius: 5px;
    cursor: pointer;
    background: var(--color-surface);
    font-size: 13px;
    color: var(--color-fg);
  }
  .option:hover {
    background: var(--color-surface-soft);
  }
  .option.selected {
    background: var(--color-surface-soft);
    border-color: var(--color-fg-subtle);
  }
  .option input {
    margin: 0;
  }
  input[type="text"],
  input[type="number"],
  textarea {
    border: 1px solid var(--color-border);
    background: var(--color-surface);
    color: var(--color-fg);
    border-radius: 5px;
    padding: 0.45rem 0.625rem;
    font: inherit;
    font-size: 13px;
    width: 100%;
    box-sizing: border-box;
  }
  textarea {
    resize: vertical;
    font-family: inherit;
    line-height: 1.45;
  }
  input:focus,
  textarea:focus {
    outline: 2px solid var(--color-ring);
    outline-offset: -1px;
  }
</style>

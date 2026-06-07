<script lang="ts">
  /**
   * wb-i38o.10 — raw source pane for the org editor.
   *
   * CodeMirror 6 editor configured as plain text + monospace + line
   * numbers + bracket matching. No org-mode grammar — neither
   * codemirror's standard set nor a maintained community port exists
   * with parity to org-mode's structural rules (headlines, drawers,
   * begin_src blocks, link syntax). Real syntax highlighting is a
   * follow-up (filed below).
   *
   * Buffer changes fire `onChange(text)` after every keystroke. The
   * parent debounces the live-preview render.
   *
   * Cmd+S / Ctrl+S triggers `onSave()`. The parent owns disk I/O.
   */
  import { onMount, onDestroy } from "svelte";
  import { EditorState } from "@codemirror/state";
  import {
    EditorView,
    keymap,
    lineNumbers,
    highlightActiveLineGutter,
    highlightActiveLine,
  } from "@codemirror/view";
  import {
    syntaxHighlighting,
    defaultHighlightStyle,
    bracketMatching,
    indentOnInput,
  } from "@codemirror/language";
  import { history, defaultKeymap, historyKeymap } from "@codemirror/commands";
  import { searchKeymap, highlightSelectionMatches } from "@codemirror/search";

  let {
    initial,
    onChange,
    onSave,
  }: {
    initial: string;
    onChange: (next: string) => void;
    onSave: () => void;
  } = $props();

  let host: HTMLDivElement;
  let view: EditorView | null = null;

  function mount() {
    view?.destroy();
    const state = EditorState.create({
      doc: initial,
      extensions: [
        lineNumbers(),
        highlightActiveLineGutter(),
        highlightActiveLine(),
        history(),
        bracketMatching(),
        indentOnInput(),
        highlightSelectionMatches(),
        syntaxHighlighting(defaultHighlightStyle, { fallback: true }),
        EditorView.lineWrapping,
        keymap.of([
          // Cmd+S / Ctrl+S → save. Defined before defaultKeymap so it
          // wins over the browser's "save page" handler (Tauri WebView
          // wouldn't show that dialog anyway, but the precedence keeps
          // future browser-target builds well-behaved).
          {
            key: "Mod-s",
            preventDefault: true,
            run: () => {
              onSave();
              return true;
            },
          },
          ...defaultKeymap,
          ...historyKeymap,
          ...searchKeymap,
        ]),
        EditorView.updateListener.of((u) => {
          if (u.docChanged) {
            onChange(u.state.doc.toString());
          }
        }),
        EditorView.theme({
          "&": {
            fontSize: "13px",
            height: "100%",
          },
          ".cm-scroller": {
            fontFamily:
              "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace",
          },
          ".cm-gutters": {
            backgroundColor: "transparent",
            borderRight: "1px solid var(--color-border)",
          },
        }),
      ],
    });
    view = new EditorView({ state, parent: host });
  }

  onMount(() => {
    mount();
  });

  onDestroy(() => {
    view?.destroy();
    view = null;
  });
</script>

<div class="host" bind:this={host}></div>

<style>
  .host {
    flex: 1 1 auto;
    min-height: 0;
    min-width: 0;
    overflow: hidden;
    display: flex;
    flex-direction: column;
  }
  .host :global(.cm-editor) {
    height: 100%;
  }
  .host :global(.cm-editor.cm-focused) {
    outline: none;
  }
</style>

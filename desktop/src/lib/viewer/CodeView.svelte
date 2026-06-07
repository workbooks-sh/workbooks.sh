<script lang="ts">
  /**
   * wb-i38o.8 — CodeView. Read-only CodeMirror 6 viewer.
   *
   * v1 is read-only — no editing. D10 (`Org file viewer + minimal
   * editor`) is the next slice that opens up writes. The language is
   * picked from the file extension via dynamic `@codemirror/lang-*`
   * imports. Unknown extensions render as plain text.
   */
  import { onMount, onDestroy } from "svelte";
  import { invoke } from "@tauri-apps/api/core";
  import { EditorState } from "@codemirror/state";
  import { EditorView, lineNumbers, highlightActiveLineGutter } from "@codemirror/view";
  import {
    syntaxHighlighting,
    defaultHighlightStyle,
    bracketMatching,
    foldGutter,
    indentOnInput,
  } from "@codemirror/language";

  let { path }: { path: string } = $props();

  let host: HTMLDivElement;
  let view: EditorView | null = null;
  let error = $state<string | null>(null);
  let loading = $state(true);

  function ext(p: string): string {
    const m = p.toLowerCase().match(/\.([a-z0-9]+)$/);
    return m ? m[1] : "";
  }

  async function loadLanguage(extension: string) {
    // Lazy import so unused languages don't bloat the bundle.
    switch (extension) {
      case "ts":
      case "tsx":
      case "js":
      case "jsx":
      case "mjs":
      case "cjs": {
        const { javascript } = await import("@codemirror/lang-javascript");
        return javascript({
          jsx: extension.endsWith("x"),
          typescript: extension.startsWith("ts"),
        });
      }
      case "json": {
        const { json } = await import("@codemirror/lang-json");
        return json();
      }
      case "md":
      case "markdown": {
        const { markdown } = await import("@codemirror/lang-markdown");
        return markdown();
      }
      case "rs": {
        const { rust } = await import("@codemirror/lang-rust");
        return rust();
      }
      case "html":
      case "htm":
      case "svelte": {
        // svelte falls back to HTML — close enough for a viewer.
        const { html } = await import("@codemirror/lang-html");
        return html();
      }
      case "css":
      case "scss": {
        const { css } = await import("@codemirror/lang-css");
        return css();
      }
      case "yaml":
      case "yml": {
        const { yaml } = await import("@codemirror/lang-yaml");
        return yaml();
      }
      case "py": {
        const { python } = await import("@codemirror/lang-python");
        return python();
      }
      case "lua":
      case "ex":
      case "exs":
      case "toml":
      case "go":
      case "sh":
      case "bash":
      case "zsh":
      case "fish":
      default:
        // No bundled grammar — plain text. CodeMirror still gives us
        // line numbers, bracket matching, and a respectable monospace
        // gutter.
        return [];
    }
  }

  async function mount(p: string) {
    loading = true;
    error = null;
    view?.destroy();
    view = null;
    try {
      const text = await invoke<string>("read_file_text", { path: p });
      const language = await loadLanguage(ext(p));
      const state = EditorState.create({
        doc: text,
        extensions: [
          lineNumbers(),
          highlightActiveLineGutter(),
          foldGutter(),
          bracketMatching(),
          indentOnInput(),
          syntaxHighlighting(defaultHighlightStyle, { fallback: true }),
          EditorView.editable.of(false),
          EditorState.readOnly.of(true),
          // No line wrapping for code — wrapped indentation reads as
          // empty lines in the gutter and breaks visual scanning of
          // structured code. The `.cm-scroller` styling below adds
          // horizontal overflow so long lines scroll instead.
          EditorView.theme({
            "&": {
              fontSize: "13px",
              height: "100%",
            },
            ".cm-scroller": {
              fontFamily:
                "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace",
              overflowX: "auto",
            },
            ".cm-content": {
              // CodeMirror sets the content layer's white-space when
              // lineWrapping is on; without that extension we need to
              // explicitly preserve `pre` so long lines don't wrap
              // via inherited CSS, they just extend past the viewport.
              whiteSpace: "pre",
            },
            ".cm-gutters": {
              backgroundColor: "transparent",
              borderRight: "1px solid var(--color-border)",
            },
          }),
          language,
        ].flat(),
      });
      view = new EditorView({ state, parent: host });
    } catch (err) {
      error = err instanceof Error ? err.message : String(err);
    } finally {
      loading = false;
    }
  }

  onMount(() => {
    mount(path);
  });
  $effect(() => {
    if (host && path) mount(path);
  });

  onDestroy(() => {
    view?.destroy();
    view = null;
  });
</script>

<div class="wrap">
  {#if loading}
    <div class="status">Loading…</div>
  {/if}
  {#if error}
    <div class="status err">Failed to read: {error}</div>
  {/if}
  <div class="host" bind:this={host}></div>
</div>

<style>
  .wrap {
    flex: 1 1 auto;
    min-height: 0;
    display: flex;
    flex-direction: column;
  }
  .host {
    flex: 1 1 auto;
    min-height: 0;
    overflow: auto;
  }
  .status {
    padding: 0.6rem 1rem;
    font-size: 0.85rem;
    color: var(--color-fg-muted);
  }
  .status.err {
    color: #ef4444;
    font-family: ui-monospace, SFMono-Regular, monospace;
    white-space: pre-wrap;
  }
</style>

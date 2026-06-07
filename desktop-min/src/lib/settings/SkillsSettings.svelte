<script lang="ts">
  /**
   * SkillsSettings — installed agent skills with a per-skill scope.
   * Scope (Global / Workspace / Package) bounds where the agent may
   * call the skill. Remove drops it from the catalog. Marketplace
   * install is deferred with the backend.
   */
  import { onMount } from "svelte";
  import { Sparkles, Trash2 } from "@lucide/svelte";
  import { commands, type Skill } from "$lib/bindings";
  import SettingsPanel from "./SettingsPanel.svelte";

  let skills = $state<Skill[]>([]);

  const scopes: { value: Skill["scope"]; label: string }[] = [
    { value: "global", label: "Global" },
    { value: "workspace", label: "Workspace" },
    { value: "package", label: "Package" },
  ];

  onMount(async () => {
    skills = await commands.skillsList();
  });

  async function setScope(s: Skill, scope: string) {
    await commands.skillsSetScope({ id: s.id, scope });
    skills = skills.map((x) => (x.id === s.id ? { ...x, scope: scope as Skill["scope"] } : x));
  }

  async function remove(s: Skill) {
    await commands.skillsDelete(s.id);
    skills = skills.filter((x) => x.id !== s.id);
  }
</script>

<SettingsPanel title="Skills" lede="Agent-callable capability bundles. Set each skill's scope to bound where the agent can use it.">
  {#if skills.length === 0}
    <p class="empty"><Sparkles size={14} strokeWidth={1.8} /> No skills installed yet.</p>
  {:else}
    <ul class="list">
      {#each skills as s (s.id)}
        <li class="row">
          <span class="ico"><Sparkles size={14} strokeWidth={1.8} /></span>
          <span class="body">
            <span class="title">{s.name}</span>
            <span class="meta"><code>{s.slug}</code></span>
          </span>
          <select class="scope" value={s.scope} onchange={(e) => setScope(s, e.currentTarget.value)}>
            {#each scopes as sc (sc.value)}
              <option value={sc.value}>{sc.label}</option>
            {/each}
          </select>
          <button class="del" title="Remove" aria-label="Remove" onclick={() => remove(s)}>
            <Trash2 size={13} strokeWidth={1.8} />
          </button>
        </li>
      {/each}
    </ul>
  {/if}
</SettingsPanel>

<style>
  .empty {
    margin: 0;
    display: flex;
    align-items: center;
    gap: 0.4rem;
    font-size: 0.82rem;
    color: var(--color-fg-muted);
  }
  .list {
    list-style: none;
    margin: 0;
    padding: 0;
    display: flex;
    flex-direction: column;
    gap: 0.25rem;
  }
  .row {
    display: flex;
    align-items: center;
    gap: 0.6rem;
    padding: 0.45rem 0.5rem;
    border: 1px solid transparent;
    border-radius: 8px;
  }
  .row:hover {
    background: var(--color-surface-soft);
    border-color: var(--color-border);
  }
  .ico {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 28px;
    height: 28px;
    flex-shrink: 0;
    border-radius: 7px;
    border: 1px solid var(--color-border);
    background: var(--color-surface);
    color: var(--color-fg-muted);
  }
  .body {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 0.05rem;
  }
  .title {
    font-size: 0.84rem;
    font-weight: 600;
  }
  .meta {
    font-size: 0.72rem;
    color: var(--color-fg-muted);
  }
  .meta code {
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  }
  .scope {
    height: 28px;
    padding: 0 0.4rem;
    border-radius: 7px;
    border: 1px solid var(--color-border);
    background: var(--color-surface-soft);
    color: var(--color-fg);
    font: inherit;
    font-size: 0.74rem;
    cursor: pointer;
  }
  .del {
    flex-shrink: 0;
    padding: 0.3rem;
    border: 0;
    border-radius: 5px;
    background: transparent;
    color: var(--color-fg-subtle);
    cursor: pointer;
  }
  .del:hover {
    background: var(--color-border);
    color: var(--color-err);
  }
</style>

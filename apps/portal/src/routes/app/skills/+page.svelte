<!--
  /app/skills — download brandnana skill bundles for various agent runtimes.
  No bearer needed for the download itself; the skills are public docs.
-->
<script lang="ts">
  import { onMount } from "svelte";
  import { env as pub } from "$env/dynamic/public";

  const API_BASE = pub.PUBLIC_BRANDNANA_API_BASE ?? "https://api.brandnana.net";

  const TARGETS = [
    {
      key: "claude-code",
      name: "Claude Code",
      tagline: "Drops .md files into your ~/.claude/skills/ for auto-load.",
      install: "tar -xzf brandnana-skills-claude-code.tar.gz -C ~/.claude/skills/",
    },
    {
      key: "cursor",
      name: "Cursor",
      tagline: ".md files for .cursor/rules/ — @-mention them in chat.",
      install: "tar -xzf brandnana-skills-cursor.tar.gz -C .cursor/rules/",
    },
    {
      key: "generic",
      name: "Any agent",
      tagline: "Raw markdown — drop anywhere your tool reads docs.",
      install: "tar -xzf brandnana-skills-generic.tar.gz",
    },
  ];

  let skills = $state<Array<{ path: string; title: string; description: string }>>([]);
  let loading = $state(true);

  onMount(async () => {
    try {
      const r = await fetch(`${API_BASE}/v1/skills/list`);
      if (r.ok) {
        const data = (await r.json()) as { skills: typeof skills };
        skills = data.skills;
      }
    } finally {
      loading = false;
    }
  });
</script>

<svelte:head>
  <title>skills · brandnana</title>
</svelte:head>

<div class="flex flex-col gap-6 max-w-3xl">
  <div class="flex flex-col gap-1">
    <h2 class="font-serif text-base font-normal text-fg tracking-tight">skills</h2>
    <p class="text-fg-muted text-xs">
      Drop these into your coding agent so it knows how to call brandnana.
    </p>
  </div>

  <div class="grid grid-cols-1 md:grid-cols-3 gap-3">
    {#each TARGETS as t}
      <div class="rounded-lg border border-line p-4 flex flex-col gap-2">
        <div class="font-medium text-fg text-[14px]">{t.name}</div>
        <div class="text-fg-muted text-[12px] flex-1">{t.tagline}</div>
        <a
          href="{API_BASE}/v1/skills/bundle.tar.gz?target={t.key}"
          class="mt-2 inline-block text-center py-1.5 px-3 rounded-md bg-banana hover:bg-banana-soft text-fg text-[12.5px] font-medium transition-colors"
          download="brandnana-skills-{t.key}.tar.gz"
        >
          Download
        </a>
        <code class="text-[10.5px] font-mono text-fg-subtle break-all mt-1">{t.install}</code>
      </div>
    {/each}
  </div>

  <div class="flex flex-col gap-3">
    <div class="text-[12px] uppercase tracking-wider text-fg-muted">included files</div>
    {#if loading}
      <div class="text-fg-muted text-[13px]">loading…</div>
    {:else}
      <div class="divide-y divide-line border border-line rounded-lg overflow-hidden">
        {#each skills as s}
          <a
            href="{API_BASE}/v1/skills/file/{s.path}"
            target="_blank"
            rel="noreferrer"
            class="flex items-baseline justify-between px-4 py-3 hover:bg-bg-soft transition-colors"
          >
            <div>
              <div class="text-[13.5px] text-fg">{s.title}</div>
              <div class="text-[12px] text-fg-muted">{s.description}</div>
            </div>
            <code class="font-mono text-[11px] text-fg-subtle">{s.path}</code>
          </a>
        {/each}
      </div>
    {/if}
  </div>

  <div class="rounded-lg bg-bg-soft border border-line p-4">
    <div class="text-[12px] uppercase tracking-wider text-fg-muted mb-2">also available</div>
    <p class="text-[13px] text-fg">
      <code class="font-mono text-[12px]">brandnana login</code> from the CLI authenticates via this site —
      no API-key copy-paste required.
    </p>
  </div>
</div>

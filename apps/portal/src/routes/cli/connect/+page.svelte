<!--
  /cli/connect?code=ABCD-1234 — server-rendered. Form actions handle approve/deny.
-->
<script lang="ts">
  import { enhance } from "$app/forms";
  import type { PageData, ActionData } from "./$types";

  let { data, form }: { data: PageData; form: ActionData } = $props();
  let busy = $state(false);
</script>

<svelte:head><title>authorize CLI · brandnana</title></svelte:head>

<div class="min-h-screen flex flex-col bg-white text-fg">
  <header class="px-6 md:px-10 py-5 flex items-center justify-between">
    <a href="/" class="flex items-center gap-2 text-fg font-medium tracking-tight">
      <span class="font-serif text-[20px] leading-none">brandnana</span>
      <span class="inline-block w-1.5 h-1.5 rounded-full bg-banana"></span>
    </a>
    <span class="text-[12px] text-fg-muted uppercase tracking-wider">cli auth</span>
  </header>

  <main class="flex-1 grid place-items-center px-6 pb-16">
    <div class="w-full max-w-lg">
      {#if data.lookupError}
        <div class="rounded-lg bg-red-50 border border-red-200 text-red-700 text-[13px] p-4">
          {data.lookupError}
        </div>
      {:else if form?.ok && form.decision === "approve"}
        <h1 class="font-serif text-[32px] leading-tight tracking-tight mb-3">Authorized.</h1>
        <p class="text-fg-muted text-[15px] mb-6">Close this window — your CLI should now be signed in.</p>
        <a href="/app/keys" class="inline-block py-2 px-4 rounded-lg bg-banana hover:bg-banana-soft text-fg text-[13.5px] font-medium transition-colors">View keys →</a>
      {:else if form?.ok && form.decision === "deny"}
        <h1 class="font-serif text-[28px] leading-tight tracking-tight mb-3">Request denied.</h1>
        <p class="text-fg-muted text-[14px]">Your CLI will report that authorization was denied.</p>
      {:else if data.lookup && (data.lookup.status === "expired" || data.lookup.status === "consumed" || data.lookup.status === "denied")}
        <h1 class="font-serif text-[28px] leading-tight tracking-tight mb-3">Code is no longer valid.</h1>
        <p class="text-fg-muted text-[14px]">
          Status: <code class="font-mono">{data.lookup.status}</code>. Re-run <code class="font-mono">brandnana login</code> for a fresh code.
        </p>
      {:else if data.lookup && data.lookup.status === "approved"}
        <h1 class="font-serif text-[28px] leading-tight tracking-tight mb-3">Already approved.</h1>
        <p class="text-fg-muted text-[14px]">Your CLI should pick up the key automatically.</p>
      {:else if data.lookup}
        <h1 class="font-serif text-[32px] leading-tight tracking-tight mb-2">Authorize your CLI?</h1>
        <p class="text-fg-muted text-[15px] mb-6">
          A brandnana CLI on this machine is asking to sign in as you.
          Confirm the code matches what your terminal shows.
        </p>

        <div class="rounded-xl border-2 border-banana bg-banana-soft p-5 mb-4 text-center">
          <div class="text-[11px] uppercase tracking-wider text-fg-muted mb-1">code shown by CLI</div>
          <div class="font-mono text-[28px] text-fg tracking-[0.2em] font-semibold">{data.code}</div>
        </div>

        {#if data.lookup.client_info}
          <div class="rounded-lg bg-bg-soft border border-line p-4 mb-5 text-[12px] text-fg-muted font-mono">
            {JSON.stringify(data.lookup.client_info)}
          </div>
        {/if}

        {#if form?.error}
          <div class="rounded-lg bg-red-50 border border-red-200 text-red-700 text-[13px] p-3 mb-4">{form.error}</div>
        {/if}

        <div class="flex gap-3">
          <form
            method="POST"
            action="?/approve"
            use:enhance={() => { busy = true; return ({ update }) => update().then(() => (busy = false)); }}
            class="flex-1"
          >
            <input type="hidden" name="code" value={data.code} />
            <button type="submit" disabled={busy}
              class="w-full py-3 rounded-lg bg-banana hover:bg-banana-soft text-fg font-semibold transition-colors disabled:opacity-40">
              {busy ? "approving…" : "Approve"}
            </button>
          </form>
          <form method="POST" action="?/deny" use:enhance>
            <input type="hidden" name="code" value={data.code} />
            <button type="submit" disabled={busy}
              class="py-3 px-4 rounded-lg border border-line text-fg-muted hover:text-fg hover:bg-bg-soft transition-colors disabled:opacity-40">
              Deny
            </button>
          </form>
        </div>

        <p class="text-[11px] text-fg-subtle mt-4 text-center">
          Only approve if you started <code class="font-mono">brandnana login</code> just now.
        </p>
      {/if}
    </div>
  </main>
</div>

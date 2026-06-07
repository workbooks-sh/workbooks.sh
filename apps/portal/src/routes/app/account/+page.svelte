<script lang="ts">
  import { onMount } from "svelte";
  import { getAccount, ApiError } from "$lib/api.js";
  import type { AccountInfo } from "$lib/api.js";
  import { clearToken } from "$lib/auth.js";
  import { goto } from "$app/navigation";
  import Spinner from "$lib/components/Spinner.svelte";

  let account = $state<AccountInfo | null>(null);
  let loading = $state(true);
  let error = $state("");

  onMount(async () => {
    try {
      account = await getAccount();
    } catch (e) {
      error = e instanceof ApiError ? `${e.status}: ${e.message}` : String(e);
    } finally {
      loading = false;
    }
  });

  function signOut() {
    clearToken();
    goto("/");
  }

  function pct(used: number, cap: number): number {
    if (cap === 0) return 0;
    return Math.min(100, Math.round((used / cap) * 100));
  }

  function fmtNum(n: number): string {
    return n.toLocaleString("en-US");
  }

  function fmtDollar(n: number): string {
    return "$" + n.toFixed(2);
  }
</script>

<div class="flex flex-col gap-4">
  <div class="mb-1">
    <h2 class="font-serif text-base font-normal text-fg tracking-tight">account</h2>
  </div>

  {#if loading}
    <div class="flex items-center gap-2 text-fg-muted text-xs py-4">
      <Spinner size={16} /> loading…
    </div>
  {:else if error}
    <p class="error text-xs">{error}</p>
  {:else if account}
    <div class="section">
      <div class="section-title">identity</div>
      <dl class="flex flex-col gap-2">
        <div class="flex items-center gap-3 text-xs">
          <dt class="subtle text-xs min-w-24">email</dt>
          <dd class="m-0">{account.email}</dd>
        </div>
        <div class="flex items-center gap-3 text-xs">
          <dt class="subtle text-xs min-w-24">plan</dt>
          <dd class="m-0">
            <span class="chip ok">{account.plan}</span>
          </dd>
        </div>
      </dl>
    </div>

    <div class="section">
      <div class="section-title">usage this period</div>
      <dl class="flex flex-col gap-2 mb-3">
        <div class="flex items-center gap-3 text-xs">
          <dt class="subtle text-xs min-w-24">api calls</dt>
          <dd class="m-0">
            <span class={pct(account.calls_used, account.calls_per_month) > 80 ? "warn" : ""}>
              {fmtNum(account.calls_used)} / {fmtNum(account.calls_per_month)}
            </span>
            <span class="muted">&nbsp;({pct(account.calls_used, account.calls_per_month)}%)</span>
          </dd>
        </div>
        <div class="flex items-center gap-3 text-xs">
          <dt class="subtle text-xs min-w-24">spend cap</dt>
          <dd class="m-0">
            <span class={pct(account.dollar_used, account.dollar_cap) > 80 ? "warn" : ""}>
              {fmtDollar(account.dollar_used)} / {fmtDollar(account.dollar_cap)}
            </span>
            <span class="muted">&nbsp;({pct(account.dollar_used, account.dollar_cap)}%)</span>
          </dd>
        </div>
      </dl>

      <div class="flex flex-col gap-2">
        <div class="flex items-center gap-2.5 text-xs">
          <span class="subtle text-xs min-w-10">calls</span>
          <div class="flex-1 h-1 bg-border-warm max-w-60">
            <div
              class="h-full transition-all"
              class:bar-warn={pct(account.calls_used, account.calls_per_month) > 80}
              style="width:{pct(account.calls_used, account.calls_per_month)}%; background: {pct(account.calls_used, account.calls_per_month) > 80 ? 'var(--color-warn)' : 'var(--color-fg-muted)'}"
            ></div>
          </div>
        </div>
        <div class="flex items-center gap-2.5 text-xs">
          <span class="subtle text-xs min-w-10">spend</span>
          <div class="flex-1 h-1 bg-border-warm max-w-60">
            <div
              class="h-full transition-all"
              style="width:{pct(account.dollar_used, account.dollar_cap)}%; background: {pct(account.dollar_used, account.dollar_cap) > 80 ? 'var(--color-warn)' : 'var(--color-fg-muted)'}"
            ></div>
          </div>
        </div>
      </div>
    </div>

    <div class="section">
      <div class="section-title">session</div>
      <button class="btn danger" onclick={signOut} type="button">
        [sign out]
      </button>
    </div>
  {/if}
</div>

<script lang="ts">
  import { onMount } from "svelte";
  import { getConnectionStatus, ApiError } from "$lib/api.js";
  import type { ConnectionStatus } from "$lib/api.js";
  import Spinner from "$lib/components/Spinner.svelte";

  type Provider = "meta" | "tiktok" | "google";

  interface ProviderDef {
    id: Provider;
    label: string;
    handle_label: string;
  }

  const PROVIDERS: ProviderDef[] = [
    { id: "meta", label: "Meta (Facebook/Instagram)", handle_label: "ad account" },
    { id: "tiktok", label: "TikTok", handle_label: "advertiser id" },
    { id: "google", label: "Google Ads", handle_label: "customer id" },
  ];

  let statuses = $state<Record<Provider, ConnectionStatus | null | "loading" | "error">>({
    meta: "loading",
    tiktok: "loading",
    google: "loading",
  });

  onMount(async () => {
    await Promise.all(
      PROVIDERS.map(async (p) => {
        try {
          const s = await getConnectionStatus(p.id);
          statuses[p.id] = s;
        } catch (e) {
          if (e instanceof ApiError && e.status === 401) {
            statuses[p.id] = null;
          } else {
            statuses[p.id] = "error";
          }
        }
      }),
    );
  });

  function fmt(ts: string | null): string {
    if (!ts) return "—";
    return new Date(ts).toISOString().slice(0, 16).replace("T", " ") + " UTC";
  }

  function reconnect(s: ConnectionStatus) {
    if (s.reconnect_url) window.location.href = s.reconnect_url;
  }
</script>

<div class="flex flex-col gap-4">
  <div class="flex flex-col gap-1 mb-1">
    <h2 class="font-serif text-base font-normal text-fg tracking-tight">connections</h2>
    <p class="text-fg-muted text-xs">
      OAuth tokens for ad platform integrations. Tokens refresh automatically; reconnect if expired.
    </p>
  </div>

  {#each PROVIDERS as provider (provider.id)}
    {@const status = statuses[provider.id]}
    <div class="bg-bg-cream border border-border-warm rounded-sm px-4 py-3 flex flex-col gap-3">
      <div class="flex items-center gap-2.5">
        <span class="text-fg text-sm">{provider.label}</span>
        {#if status === "loading"}
          <Spinner size={13} />
        {:else if status === "error" || status === null}
          <span class="chip error">[error]</span>
        {:else if status.connected && status.token_state === "valid"}
          <span class="chip ok">[connected]</span>
        {:else if status.connected && status.token_state === "expired"}
          <span class="chip warn">[token expired]</span>
        {:else}
          <span class="chip">[not connected]</span>
        {/if}
      </div>

      {#if status === "loading"}
        <p class="muted text-xs">fetching status…</p>
      {:else if status === "error"}
        <p class="error text-xs">failed to load status</p>
      {:else if status === null}
        <p class="subtle text-xs">authentication required</p>
      {:else}
        <dl class="flex flex-col gap-1.5">
          <div class="flex gap-3 text-xs">
            <dt class="subtle min-w-28 text-xs pt-px">{provider.handle_label}</dt>
            <dd class="m-0">{status.handle ?? status.account_id ?? "—"}</dd>
          </div>
          <div class="flex gap-3 text-xs">
            <dt class="subtle min-w-28 text-xs pt-px">token state</dt>
            <dd class="m-0 {status.token_state === 'valid' ? 'ok' : status.token_state === 'expired' ? 'warn' : 'subtle'}">
              {status.token_state}
            </dd>
          </div>
          <div class="flex gap-3 text-xs">
            <dt class="subtle min-w-28 text-xs pt-px">last refresh</dt>
            <dd class="m-0 muted">{fmt(status.last_refresh)}</dd>
          </div>
        </dl>
        <div class="flex gap-2">
          <button
            class="btn"
            onclick={() => reconnect(status as ConnectionStatus)}
            type="button"
          >
            [reconnect]
          </button>
        </div>
      {/if}
    </div>
  {/each}
</div>

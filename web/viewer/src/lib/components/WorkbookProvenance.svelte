<script lang="ts">
  /**
   * WorkbookProvenance — runs the manifest verifier over raw
   * workbook `.html` bytes and renders ProvenanceBadge with the
   * resolved state. Use this in the Viewer + anywhere else that
   * needs a "did this workbook come from who it claims to" badge.
   *
   * Calls into lib/network/verify.ts (TS-side reimplementation of
   * the Rust workbooks-manifest crate; cross-impl-locked).
   */
  import { onMount } from "svelte";
  import ProvenanceBadge from "./ProvenanceBadge.svelte";
  import { verifyHtml, type VerifyReport, type VerifyFail } from "$lib/verify";
  import { resolveDid, type IdentityView } from "$lib/broker";
  import ModifiedWarningBanner from "./ModifiedWarningBanner.svelte";
  import LineageTree from "./LineageTree.svelte";
  import { GitCommitVertical, ChevronDown, ChevronUp } from "@lucide/svelte";

  let {
    html,
    showDuringCheck = true,
    /** When true, render the full-width modified-warning strip ABOVE
     *  the badge (wb-u2o0.5.3). Default false — the inline badge is
     *  enough for compact contexts. Loud surfaces (Viewer header,
     *  PreviewPane) opt in. */
    showModifiedBanner = false,
    /** When true, expose a "See provenance chain" toggle that opens
     *  a LineageTree panel underneath (wb-u2o0.6.1). Default false —
     *  only loud surfaces (Viewer header) opt in. */
    showLineageToggle = false,
    /** RID for the workbook being verified — required for the
     *  "Fetch authoritative" affordance to be enabled. */
    rid = null,
    /** Caller-provided handler for "Fetch authoritative". Pulls the
     *  canonical bytes via Radicle (Workhorse-side). When omitted,
     *  the button is rendered disabled. */
    onfetchauthoritative = null,
  }: {
    html: string;
    showDuringCheck?: boolean;
    showModifiedBanner?: boolean;
    showLineageToggle?: boolean;
    rid?: string | null;
    onfetchauthoritative?: (() => void) | null;
  } = $props();

  let lineageOpen = $state(false);

  let bannerDismissed = $state(false);
  let bannerFetching = $state(false);

  async function handleFetchAuthoritative() {
    if (!onfetchauthoritative || bannerFetching) return;
    bannerFetching = true;
    try {
      await onfetchauthoritative();
    } finally {
      bannerFetching = false;
    }
  }

  type Status = "checking" | "ok" | "fail";
  let status = $state<Status>("checking");
  let result = $state<VerifyReport | VerifyFail | null>(null);
  let resolvedIssuer = $state<IdentityView | null>(null);

  onMount(async () => {
    try {
      const r = await verifyHtml(html);
      result = r;
      status = r.ok ? "ok" : "fail";

      // If verify succeeded, ask the Broker to map issuer_did →
      // identity so we can surface @handle + (when WorkOS-bound) the
      // real name. DemoModeError swallowed silently — the demo data
      // fallback below handles it.
      if (r.ok) {
        try {
          resolvedIssuer = await resolveDid(r.issuer_did);
        } catch {
          // Network/Broker error — just don't show a handle. The
          // badge still surfaces "verified" without naming the person.
          resolvedIssuer = null;
        }
      }
    } catch (e) {
      // Defensive — verifyHtml is supposed to never throw, but if it
      // does (e.g., crypto failure in an unusual env), treat as fail.
      result = {
        ok: false,
        reason: "envelope_malformed",
        detail: e instanceof Error ? e.message : String(e),
      };
      status = "fail";
    }
  });

  // Prefer the Broker-resolved identity. Fall back to demo lookup
  // when running without a sidecar.
  const issuerHandle = $derived.by(() => {
    if (resolvedIssuer) return resolvedIssuer.handle;
    return null;
  });

  // Real name from WorkOS-bound identity only (Viewer has no local
  // demo fixture surface — desktop's WorkbookProvenance falls back
  // to a demo PEOPLE list, but here we only show the truly-verified
  // name or nothing).
  const issuerRealName = $derived<string | null>(
    resolvedIssuer?.workos_display_name ?? null,
  );

  // Map verifier result → ProvenanceBadge state.
  // - ok                        → "verified"
  // - reason asset_modified     → "modified"
  // - everything else           → "unverified"
  const badgeState = $derived.by<"verified" | "unverified" | "modified">(() => {
    if (!result) return "unverified";
    if (result.ok) return "verified";
    if (result.reason === "asset_modified") return "modified";
    return "unverified";
  });
</script>

{#if status === "checking" && showDuringCheck}
  <span class="checking" aria-label="Verifying provenance">
    <span class="spinner" aria-hidden="true"></span>
    verifying…
  </span>
{:else if status !== "checking"}
  {#if showModifiedBanner && badgeState === "modified" && !bannerDismissed}
    <ModifiedWarningBanner
      by={issuerHandle}
      {rid}
      fetching={bannerFetching}
      onfetchauthoritative={handleFetchAuthoritative}
      ondismiss={() => (bannerDismissed = true)}
    />
  {/if}
  <div class="row">
    <ProvenanceBadge
      state={badgeState}
      by={issuerHandle ?? undefined}
      realName={issuerRealName}
      subject="artifact"
    />
    {#if showLineageToggle && result?.ok}
      <button
        type="button"
        class="lineage-toggle"
        onclick={() => (lineageOpen = !lineageOpen)}
        aria-expanded={lineageOpen}
      >
        <GitCommitVertical size={11} strokeWidth={2.25} />
        {lineageOpen ? "Hide" : "See"} provenance chain
        {#if lineageOpen}
          <ChevronUp size={11} strokeWidth={2.25} />
        {:else}
          <ChevronDown size={11} strokeWidth={2.25} />
        {/if}
      </button>
    {/if}
  </div>
  {#if showLineageToggle && lineageOpen && result?.ok}
    <LineageTree report={result} />
  {/if}
{/if}

<style>
  .row {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-wrap: wrap;
  }
  .lineage-toggle {
    display: inline-flex;
    align-items: center;
    gap: 3px;
    padding: 2px 8px 2px 6px;
    border-radius: 999px;
    background: transparent;
    border: 1px solid var(--color-border);
    color: var(--color-fg-muted);
    font-size: 0.66rem;
    font-weight: 500;
    cursor: pointer;
    transition: background 100ms ease, color 100ms ease;
  }
  .lineage-toggle:hover {
    background: var(--color-surface-soft);
    color: var(--color-fg);
  }
  .checking {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 2.5px 8px 2.5px 6px;
    border-radius: 999px;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    color: var(--color-fg-muted);
    font-size: 0.7rem;
    font-weight: 500;
  }
  .spinner {
    display: inline-block;
    width: 10px;
    height: 10px;
    border-radius: 50%;
    border: 1.5px solid var(--color-border);
    border-top-color: var(--color-fg-muted);
    animation: spin 900ms linear infinite;
  }
  @keyframes spin { to { transform: rotate(360deg); } }
</style>

<script lang="ts">
  import Wordmark from "../ds/Wordmark.svelte";

  interface Props { signedIn?: boolean }
  let { signedIn = false }: Props = $props();
</script>

<header class="sticky top-0 z-30 bg-white/85 backdrop-blur-md border-b border-line">
  <div class="max-w-6xl mx-auto px-6 md:px-8 py-3.5 flex items-center justify-between gap-6">
    <div class="flex items-center gap-8">
      <Wordmark size="sm" />
      <nav class="hidden md:flex items-center gap-6 text-[13px] text-fg-muted">
        <a href="/docs" class="hover:text-fg transition-colors no-underline">Docs</a>
        <a href="/pricing" class="hover:text-fg transition-colors no-underline">Pricing</a>
        <a href="https://github.com/workbooks-sh/brandnana" target="_blank" rel="noreferrer" class="hover:text-fg transition-colors no-underline">GitHub</a>
      </nav>
    </div>
    <div class="flex items-center gap-2">
      {#if signedIn}
        <a href="https://app.brandnana.net/" class="inline-flex items-center gap-1 rounded-lg bg-banana hover:bg-banana-deep text-fg text-[13px] font-semibold px-4 py-2 no-underline transition-colors">
          Open portal →
        </a>
      {:else}
        <a href="https://app.brandnana.net/app/auth/sign-in" class="text-[13px] text-fg-muted hover:text-fg transition-colors no-underline px-3 py-2">Sign in</a>
        <a href="https://app.brandnana.net/app/auth/sign-up" class="inline-flex items-center gap-1 rounded-lg bg-banana hover:bg-banana-deep text-fg text-[13px] font-semibold px-4 py-2 no-underline transition-colors">
          Sign up →
        </a>
      {/if}
    </div>
  </div>
</header>

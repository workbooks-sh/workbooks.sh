<!--
  Sign-in page. Plain <form method="POST"> — works with JavaScript disabled.
  All auth happens in +page.server.ts.
-->
<script lang="ts">
  import { enhance } from "$app/forms";
  import type { ActionData } from "./$types";

  let { form }: { form: ActionData } = $props();
  let busy = $state(false);
</script>

<svelte:head>
  <title>sign in · brandnana</title>
</svelte:head>

<div class="space-y-6">
  <div>
    <h1 class="font-serif text-[32px] leading-tight tracking-tight text-fg">Welcome back.</h1>
    <p class="text-fg-muted text-[14px] mt-2">Sign in to brandnana to manage your API keys and download skills.</p>
  </div>

  {#if form?.error}
    <div class="rounded-lg bg-red-50 border border-red-200 text-red-700 text-[13px] p-3">
      {form.error}
    </div>
  {/if}

  <form
    method="POST"
    use:enhance={() => {
      busy = true;
      return ({ update }) => update().then(() => (busy = false));
    }}
    class="space-y-4"
  >
    <div>
      <label class="block text-[12px] text-fg-muted mb-1.5" for="email">Email</label>
      <input
        id="email"
        name="email"
        type="email"
        autocomplete="email"
        required
        value={form?.email ?? ""}
        class="w-full px-4 py-2.5 rounded-lg border border-line focus:border-blue-deep focus:ring-2 focus:ring-blue-deep/15 outline-none text-[15px]"
      />
    </div>
    <div>
      <label class="block text-[12px] text-fg-muted mb-1.5" for="password">Password</label>
      <input
        id="password"
        name="password"
        type="password"
        autocomplete="current-password"
        required
        class="w-full px-4 py-2.5 rounded-lg border border-line focus:border-blue-deep focus:ring-2 focus:ring-blue-deep/15 outline-none text-[15px]"
      />
    </div>
    <button
      type="submit"
      disabled={busy}
      class="w-full py-2.5 rounded-lg bg-banana hover:bg-banana-soft text-fg font-semibold transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
    >
      {busy ? "signing in…" : "Sign in"}
    </button>
  </form>

  <p class="text-[13px] text-fg-muted text-center">
    No account?
    <a href="/app/auth/sign-up" class="text-blue-deep hover:underline">Sign up →</a>
  </p>
</div>

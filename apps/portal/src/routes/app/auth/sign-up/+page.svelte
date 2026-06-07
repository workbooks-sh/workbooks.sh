<!--
  Sign-up page. Plain <form method="POST">. All auth lives in +page.server.ts.
-->
<script lang="ts">
  import { enhance } from "$app/forms";
  import type { ActionData } from "./$types";

  let { form }: { form: ActionData } = $props();
  let busy = $state(false);
</script>

<svelte:head>
  <title>create account · brandnana</title>
</svelte:head>

<div class="space-y-6">
  <div>
    <h1 class="font-serif text-[32px] leading-tight tracking-tight text-fg">Get started.</h1>
    <p class="text-fg-muted text-[14px] mt-2">A brandnana account gets you an API key, the CLI, and downloadable skills.</p>
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
      <label class="block text-[12px] text-fg-muted mb-1.5" for="first_name">Your name <span class="text-fg-subtle">(optional)</span></label>
      <input
        id="first_name"
        name="first_name"
        type="text"
        autocomplete="given-name"
        value={form?.firstName ?? ""}
        class="w-full px-4 py-2.5 rounded-lg border border-line focus:border-blue-deep focus:ring-2 focus:ring-blue-deep/15 outline-none text-[15px]"
      />
    </div>
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
        autocomplete="new-password"
        required
        minlength={8}
        class="w-full px-4 py-2.5 rounded-lg border border-line focus:border-blue-deep focus:ring-2 focus:ring-blue-deep/15 outline-none text-[15px]"
      />
      <p class="text-[11px] text-fg-subtle mt-1">8 characters minimum.</p>
    </div>
    <button
      type="submit"
      disabled={busy}
      class="w-full py-2.5 rounded-lg bg-banana hover:bg-banana-soft text-fg font-semibold transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
    >
      {busy ? "creating account…" : "Create account"}
    </button>
  </form>

  <p class="text-[13px] text-fg-muted text-center">
    Have an account?
    <a href="/app/auth/sign-in" class="text-blue-deep hover:underline">Sign in →</a>
  </p>
</div>

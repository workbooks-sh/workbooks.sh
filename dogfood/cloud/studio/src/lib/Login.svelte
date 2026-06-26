<script>
  // The login / signup screen. Owns native email+password and GitHub OAuth (a link to the server
  // route). When no runtime is reachable (offline), it offers "Explore the demo" so the standalone
  // build is still fully usable.
  import { auth, login, signup, enterDemo } from './auth.svelte.js'
  import { iconSvgByName } from './icons.js'

  let mode = $state('login') // 'login' | 'signup'
  let email = $state('')
  let password = $state('')
  let name = $state('')
  let busy = $state(false)
  let error = $state('')

  async function submit(e) {
    e.preventDefault()
    error = ''
    busy = true
    try {
      if (mode === 'signup') await signup(email, password, name)
      else await login(email, password)
    } catch (err) {
      error = auth.offline
        ? 'No runtime reachable. Explore the demo below, or start a nexus.'
        : (mode === 'signup' ? 'Could not create your account.' : 'Wrong email or password.')
    } finally {
      busy = false
    }
  }
</script>

<div class="min-h-screen grid place-items-center bg-paper px-6" style="background:
  radial-gradient(60% 50% at 20% 10%, color-mix(in srgb,var(--color-sky) 14%,transparent), transparent),
  radial-gradient(50% 40% at 85% 90%, color-mix(in srgb,var(--color-mint) 12%,transparent), transparent), var(--color-paper)">
  <div class="w-[min(400px,92vw)]">
    <div class="flex items-center gap-2.5 mb-7">
      <div class="w-9 h-9 rounded-xl grid place-items-center text-paper [&>svg]:w-5 [&>svg]:h-5" style="background:var(--color-ink)">{@html iconSvgByName('sparks', 20)}</div>
      <div>
        <div class="font-display font-bold text-[19px] leading-none">Studio</div>
        <div class="text-dim text-[12px] mt-0.5">the chat-native agent runtime</div>
      </div>
    </div>

    <div class="rounded-2xl border border-line bg-paper/80 backdrop-blur shadow-xl p-6">
      <div class="font-display font-semibold text-[18px] mb-1">{mode === 'signup' ? 'Create your account' : 'Welcome back'}</div>
      <div class="text-dim text-[13px] mb-5">{mode === 'signup' ? 'Spin up your team’s runtime in minutes.' : 'Sign in to your runtime.'}</div>

      <form onsubmit={submit} class="flex flex-col gap-2.5">
        {#if mode === 'signup'}
          <input bind:value={name} placeholder="Your name" autocomplete="name"
            class="bg-card border border-line rounded-xl px-3.5 py-2.5 text-[14px] focus:outline-none focus:border-[color-mix(in_srgb,var(--color-sky)_55%,var(--color-line))]" />
        {/if}
        <input bind:value={email} type="email" placeholder="you@team.com" autocomplete="email" required
          class="bg-card border border-line rounded-xl px-3.5 py-2.5 text-[14px] focus:outline-none focus:border-[color-mix(in_srgb,var(--color-sky)_55%,var(--color-line))]" />
        <input bind:value={password} type="password" placeholder="Password" autocomplete={mode === 'signup' ? 'new-password' : 'current-password'} required
          class="bg-card border border-line rounded-xl px-3.5 py-2.5 text-[14px] focus:outline-none focus:border-[color-mix(in_srgb,var(--color-sky)_55%,var(--color-line))]" />

        {#if error}<div class="text-[12.5px]" style="color:var(--color-bad,#d66)">{error}</div>{/if}

        <button type="submit" disabled={busy}
          class="mt-1 rounded-xl bg-ink text-paper py-2.5 text-[14px] font-medium hover:opacity-90 disabled:opacity-50 transition">
          {busy ? '…' : mode === 'signup' ? 'Create account' : 'Sign in'}
        </button>
      </form>

      <div class="flex items-center gap-3 my-4 text-dim text-[11px]">
        <span class="h-px flex-1 bg-line"></span>or<span class="h-px flex-1 bg-line"></span>
      </div>

      <a href="/auth/github/login"
        class="flex items-center justify-center gap-2 rounded-xl border border-line py-2.5 text-[14px] hover:bg-[color-mix(in_srgb,var(--color-ink)_5%,transparent)] [&>svg]:w-4 [&>svg]:h-4">
        {@html iconSvgByName('github', 16)} Continue with GitHub
      </a>
    </div>

    <div class="flex items-center justify-between mt-4 text-[13px] px-1">
      <button onclick={() => { mode = mode === 'login' ? 'signup' : 'login'; error = '' }} class="text-dim hover:text-ink">
        {mode === 'login' ? 'Create an account' : 'I already have an account'}
      </button>
      {#if auth.offline}
        <button onclick={enterDemo} class="font-medium" style="color:var(--color-sky)">Explore the demo →</button>
      {/if}
    </div>
  </div>
</div>

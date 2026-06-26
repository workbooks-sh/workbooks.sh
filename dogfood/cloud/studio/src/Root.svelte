<script>
  // The app shell: gates the experience by auth status — Login → Onboarding → Studio. On boot it asks
  // the backend who we are; with no runtime it falls into the standalone-demo path (Login offers
  // "Explore the demo"). This is the single seam that makes one build serve both the live dashboard and
  // the demo.
  import { auth, initAuth } from './lib/auth.svelte.js'
  import { hydrate } from './lib/hydrate.js'
  import Login from './lib/Login.svelte'
  import Onboarding from './lib/Onboarding.svelte'
  import App from './App.svelte'

  initAuth()

  // once authenticated against a real runtime, open the live-shapes socket so the store goes live.
  // Offline (demo) stays on the mock seed data — hydrate is a no-op there (socket never connects).
  $effect(() => {
    if (auth.status === 'ready' && !auth.offline) hydrate()
  })
</script>

{#if auth.status === 'loading'}
  <div class="min-h-screen grid place-items-center bg-paper">
    <div class="text-dim text-[13px] font-mono animate-pulse">Studio</div>
  </div>
{:else if auth.status === 'anon'}
  <Login />
{:else if auth.status === 'onboarding'}
  <Onboarding />
{:else}
  <App />
{/if}

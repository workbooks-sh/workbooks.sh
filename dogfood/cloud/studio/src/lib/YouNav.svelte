<script>
  // The "You" page sub-nav — the settings-style left column, ported from the legacy account sidebar
  // (Profile · Contributions · Usage · CLI access · Devices & keys · Preferences · Sign out). Clicking
  // an item sets ui.youSection; You.svelte scrolls its matching section into view and highlights here.
  import { ui } from './data.svelte.js'
  import { logout } from './auth.svelte.js'
  import { iconSvgByName } from './icons.js'

  const ITEMS = [
    { id: 'profile', icon: 'user', label: 'Profile' },
    { id: 'contributions', icon: 'activity', label: 'Contributions' },
    { id: 'usage', icon: 'reports', label: 'Usage' },
    { id: 'cli', icon: 'terminal', label: 'CLI access' },
    { id: 'devices', icon: 'key', label: 'Devices & keys' },
    { id: 'prefs', icon: 'settings', label: 'Preferences' }
  ]
</script>

<aside class="w-[264px] h-full bg-paper border-r border-line flex flex-col min-w-0">
  <!-- header mirrors the other sidebars (Studio/Files): 46px, 2.5 top margin, Franie 17px title -->
  <div class="flex items-center gap-1 px-3.5 h-[46px] flex-none mt-2.5">
    <span class="flex-1 font-display font-semibold text-[17px] tracking-tight">Account</span>
  </div>
  <nav class="flex-1 overflow-y-auto p-2.5 flex flex-col gap-0.5">
    {#each ITEMS as it}
      <button onclick={() => (ui.youSection = it.id)}
        class="flex items-center gap-2.5 px-2.5 py-2 rounded-lg text-left transition [&>span>svg]:w-[16px] [&>span>svg]:h-[16px]
          {ui.youSection === it.id ? 'bg-paper text-ink' : 'text-dim hover:text-ink hover:bg-paper/50'}">
        <span class="grid place-items-center">{@html iconSvgByName(it.icon, 16)}</span>
        <span class="text-[13.5px]">{it.label}</span>
      </button>
    {/each}
    <div class="border-t border-line my-2"></div>
    <button onclick={logout}
      class="flex items-center gap-2.5 px-2.5 py-2 rounded-lg text-left transition [&>span>svg]:w-[16px] [&>span>svg]:h-[16px] hover:bg-paper/50"
      style="color:var(--color-bad)">
      <span class="grid place-items-center">{@html iconSvgByName('log-out', 16)}</span>
      <span class="text-[13.5px]">Sign out</span>
    </button>
  </nav>
</aside>

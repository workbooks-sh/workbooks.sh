// version.js — force the view to update when a new build deploys, so nobody has to hard-refresh.
//
// We compare the ENTRY BUNDLE hash (index-<hash>.js) that the nexus serves in the HTML. That hash changes
// on every build — crucially even for a static studio deploy that does NOT restart the nexus (the older
// approach compared the injected `/_v/<hash>/` base, but asset_version is computed at mount/boot, so a
// no-restart content deploy left it stale and the reload never fired). We capture our running bundle at
// boot, poll the entry HTML (no-store) and reload the moment a different bundle is being served.
import { pushToast } from './toast.svelte.js'

const bundleFrom = (str) => { const m = (str || '').match(/index-([A-Za-z0-9_-]+)\.js/); return m ? m[1] : null }
const baseHref = () => document.querySelector('base')?.href || (location.origin + location.pathname)
// the mount we were served from (strip any /_v/<hash>/ the nexus injected) → https://host/<mount>/
const mountRoot = () => baseHref().replace(/_v\/[A-Za-z0-9]+\/$/, '')
const hasNexusBase = () => /\/_v\/[A-Za-z0-9]+\//.test(baseHref())

export function watchVersion(intervalMs = 20000) {
  if (!hasNexusBase()) return // no versioned base (standalone demo) — nothing to watch
  const mine = bundleFrom(document.documentElement.innerHTML)
  if (!mine) return
  let stopped = false
  async function tick() {
    if (stopped) return
    try {
      const html = await fetch(mountRoot(), { cache: 'no-store', credentials: 'same-origin' }).then((r) => r.text())
      const fresh = bundleFrom(html)
      if (fresh && fresh !== mine) { stopped = true; return announce() }
    } catch (_) {}
    setTimeout(tick, intervalMs)
  }
  setTimeout(tick, intervalMs)
}

function announce() {
  pushToast('Updating to the latest version…', 'info')
  setTimeout(() => location.reload(), 1600)
}

/**
 * Workbooks service-worker kill-switch.
 *
 * A previous version of workbooks.sh shipped a `sw.js` with a
 * cacheFirst fetch handler that intercepts every request on the
 * origin. The new architecture (lander + /w/<id> viewer proxy
 * + /_app/* asset proxy via _worker.js) doesn't serve the URLs
 * that old SW expected, so its `cacheFirst` chain throws on
 * fetch and breaks the workbook launch flow for any user who
 * had it registered.
 *
 * Once a service worker is registered for an origin, browsers
 * keep it alive even after we stop shipping the script. The way
 * out is to ship a NEW sw.js that replaces the old one in the
 * browser's registration and immediately tears itself down.
 *
 * What this file does:
 *   1. Skips the normal "waiting" phase so the new SW activates
 *      as soon as it installs.
 *   2. On activate: drops every cache, unregisters self, then
 *      reloads any controlled clients so they re-fetch directly
 *      from the network (and end up without a SW going forward).
 *   3. While alive (the brief window between install and the
 *      reload), pass every fetch straight through to the network
 *      so the site keeps working in the meantime.
 *
 * Browsers re-check the SW script on every navigation (and at
 * most every 24h regardless). Combined with no-cache headers
 * on /sw.js (see _headers), the upgrade reaches existing users
 * on their next visit at the latest.
 */

self.addEventListener("install", () => {
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    (async () => {
      try {
        const keys = await caches.keys();
        await Promise.all(keys.map((k) => caches.delete(k)));
      } catch (e) {
        /* best-effort cache wipe */
      }
      try {
        await self.registration.unregister();
      } catch (e) {
        /* registration may already be gone */
      }
      try {
        const clients = await self.clients.matchAll({
          includeUncontrolled: false,
          type: "window",
        });
        for (const c of clients) {
          if ("navigate" in c) {
            await c.navigate(c.url);
          }
        }
      } catch (e) {
        /* no controlled clients — nothing to reload */
      }
    })(),
  );
});

// Pass-through. No caching, no interception. If the old SW was
// caching workbooks.sh/_app/* JS bundles with bad hashes, that's
// gone — every request goes to the network.
self.addEventListener("fetch", (event) => {
  event.respondWith(fetch(event.request));
});

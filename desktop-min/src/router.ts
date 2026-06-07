/**
 * Router — the SPA route table for svelte-simple-router.
 *
 * Hash routing (Tauri loads off the filesystem, so no server to handle
 * deep links). Each view is lazy-loaded via an async `component` import
 * so the initial bundle stays small. The shell sections map 1:1 to the
 * old app's rail tabs: Create / Kanban / Network / Settings.
 *
 * Auth model: sign-in is optional, but an unreachable sidecar is a hard
 * gate. `network` additionally nudges to sign-in. The guard redirects to
 * the offline view when the sidecar is down, mirroring the old
 * SidecarOfflineOverlay.
 */

import type { RouterOptions, NavigationGuard } from "@dvcol/svelte-simple-router/models";
import { auth } from "$lib/auth.svelte";
import { chrome } from "$lib/chrome.svelte";

/** Hard gate: the sidecar must be reachable for the app to function.
 *  Signed-out is allowed (publish/network degrade gracefully). */
const requireSidecar: NavigationGuard = () => {
  if (!auth.sidecarReachable) return { name: "offline" };
  return true;
};

export const routerOptions: RouterOptions = {
  hash: true,
  routes: [
    { name: "home", path: "/", redirect: { name: "create" } },
    {
      name: "create",
      path: "/create",
      component: () => import("$lib/views/HomeView.svelte"),
      beforeEnter: (nav) => {
        chrome.section = "Create";
        return requireSidecar(nav);
      },
    },
    {
      name: "kanban",
      path: "/kanban",
      component: () => import("$lib/views/KanbanView.svelte"),
      beforeEnter: (nav) => {
        chrome.section = "Kanban";
        return requireSidecar(nav);
      },
    },
    {
      name: "entries",
      path: "/entries",
      component: () => import("$lib/views/EntriesView.svelte"),
      beforeEnter: (nav) => {
        chrome.section = "Entries";
        return requireSidecar(nav);
      },
    },
    {
      name: "network",
      path: "/network",
      component: () => import("$lib/views/NetworkView.svelte"),
      beforeEnter: (nav) => {
        chrome.section = "Network";
        return requireSidecar(nav);
      },
    },
    {
      name: "settings",
      path: "/settings",
      component: () => import("$lib/views/SettingsView.svelte"),
      beforeEnter: (nav) => {
        chrome.section = "Settings";
        return requireSidecar(nav);
      },
    },
    {
      name: "offline",
      path: "/offline",
      component: () => import("$lib/views/OfflineView.svelte"),
      beforeEnter: () => {
        chrome.section = "Offline";
        return true;
      },
    },
  ],
};

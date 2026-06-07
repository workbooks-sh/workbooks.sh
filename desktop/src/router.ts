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

/** Gate for RUNTIME-DEPENDENT views only (agents/network/sync). Workbook-native:
 *  the app opens + weaves/edits workbooks via the embedded kernel with NO runtime,
 *  so the core views (create/kanban/entries/settings/workbook) are NOT gated; only
 *  features that genuinely need the server tier redirect when it's unreachable. */
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
      beforeEnter: () => {
        chrome.section = "Create";
        return true;
      },
    },
    {
      name: "kanban",
      path: "/kanban",
      component: () => import("$lib/views/KanbanView.svelte"),
      beforeEnter: () => {
        chrome.section = "Kanban";
        return true;
      },
    },
    {
      name: "entries",
      path: "/entries",
      component: () => import("$lib/views/EntriesView.svelte"),
      beforeEnter: () => {
        chrome.section = "Entries";
        return true;
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
      beforeEnter: () => {
        chrome.section = "Settings";
        return true;
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
    {
      // Workbook-native: the LOCAL embedded kernel weaves Org → HTML, so this view
      // needs NO runtime (not sidecar-gated). The runtime is optional here.
      name: "workbook",
      path: "/workbook",
      component: () => import("$lib/views/WorkbookView.svelte"),
      beforeEnter: () => {
        chrome.section = "Workbook";
        return true;
      },
    },
  ],
};

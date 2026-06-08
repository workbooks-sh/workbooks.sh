// wb-i38o.35 — shared controller for the "create a Package" UX.
//
// Two entry points (the rail "+" and HomePanel's "+ New package")
// both open the same popover anchored at their button. The popover
// has two paths:
//
//   * Create new package → name + icon modal (mirrors workspace
//     onboarding); the new package is empty.
//   * Import folder → folder picker + name/icon modal; the picked
//     tree is recursively copied into the monorepo at
//     `~/Workbooks/monorepo/workspaces/<ws>/<pkg>/` and the new
//     Package's `folders` points at the copy. Sync across machines
//     is the user's git workflow; we do not symlink.
//
// The previous flow defaulted to a native folder picker as the
// only path — that didn't survive the Workbox-monorepo model where
// packages live inside one user-owned tree.
//
// State lives at module scope so HomePanel + AppRail share one
// instance. The actual popover + modal mount is in +page.svelte.

import { open as openDialog } from "@tauri-apps/plugin-dialog";

export type CreatePackageMode = "create" | "import";

export interface CreatePackageModalState {
  mode: CreatePackageMode;
  sourcePath?: string;
}

class CreatePackageController {
  menuOpen = $state(false);
  menuX = $state(0);
  menuY = $state(0);
  modal = $state<CreatePackageModalState | null>(null);

  /** Anchor the popover to the right of the trigger button. The rail
   *  is a vertical left-side column; we want the menu hugging the
   *  button's right edge, vertically aligned with its top. The
   *  ContextMenu primitive clamps to viewport, so corner triggers
   *  don't overflow off-screen. */
  openMenu(rect: DOMRect) {
    this.menuX = rect.right + 4;
    this.menuY = rect.top;
    this.menuOpen = true;
  }

  closeMenu() {
    this.menuOpen = false;
  }

  chooseCreate() {
    this.menuOpen = false;
    this.modal = { mode: "create" };
  }

  async chooseImport() {
    this.menuOpen = false;
    let picked: string | null;
    try {
      const result = await openDialog({
        directory: true,
        multiple: false,
        title: "Choose folder to import as a package",
      });
      picked = typeof result === "string" ? result : null;
    } catch (e) {
      console.warn("[createPackage] folder picker failed", e);
      picked = null;
    }
    if (!picked) return;
    this.modal = { mode: "import", sourcePath: picked };
  }

  closeModal() {
    this.modal = null;
  }
}

export const createPackage = new CreatePackageController();

/** Derive a sensible default package name from a filesystem path. */
export function basenameFromPath(path: string): string {
  const parts = path.split(/[\\/]/).filter(Boolean);
  return parts[parts.length - 1] ?? "";
}

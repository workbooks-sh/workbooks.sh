// File index for search (wb-aakl.19) — the cross-package file walk lifted
// out of SearchDrawer so the files/workbooks providers share it.
//
// Lazily loads every Package in the active workspace and exposes a flat
// list of (package, root, entry) for non-directory files. `ensure()` arms
// the lazy load (called when search opens); `entries` is reactive.

import { fileTree, type FsEntry } from "$lib/bridge/fs_tree.svelte";
import { packageStore, type Package as PackageDef } from "$lib/bridge/package.svelte";
import { workspaces } from "$lib/bridge/workspaces.svelte";

export interface FileHit {
  pkg: string;
  root: string;
  entry: FsEntry;
}

class FileIndex {
  #cache = $state<Record<string, PackageDef>>({});

  /** Lazily load full Package records for every name in the active
   *  workspace (mirrors FileTreePanel/SearchDrawer). Idempotent. */
  ensure(): void {
    const names = workspaces.active?.package_names ?? [];
    for (const name of names) {
      if (!this.#cache[name] && packageStore.active?.name !== name) {
        packageStore
          .load(name)
          .then((p) => (this.#cache = { ...this.#cache, [name]: p }))
          .catch(() => {});
      }
    }
  }

  #pkgFor(name: string): PackageDef | null {
    if (packageStore.active?.name === name) return packageStore.active;
    return this.#cache[name] ?? null;
  }

  get entries(): FileHit[] {
    const out: FileHit[] = [];
    const names = workspaces.active?.package_names ?? [];
    for (const name of names) {
      const p = this.#pkgFor(name);
      if (!p) continue;
      for (const root of p.folders) {
        const tree = fileTree.trees[root];
        if (!tree) continue;
        for (const e of tree.entries) {
          if (!e.is_dir) out.push({ pkg: name, root, entry: e });
        }
      }
    }
    return out;
  }
}

export const fileIndex = new FileIndex();

/** package-relative crumb like "pkg · folder/file.html". */
export function fileCrumb(hit: FileHit): string {
  const parts = hit.root.split(/[\\/]/).filter(Boolean);
  const base = parts[parts.length - 1] ?? "";
  const rel = base ? `${base}/${hit.entry.rel}` : hit.entry.rel;
  return `${hit.pkg} · ${rel}`;
}

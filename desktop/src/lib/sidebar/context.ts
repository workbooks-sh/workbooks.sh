// Sidebar SDK (wb-aakl.16) — the standard contract a sidebar layout is built
// against. The host (Sidebar.svelte) owns all the state + actions and exposes
// them through this context; each layout (Shelf / Hub / Map) and each section
// component (library, bookmarks, …) consumes the SAME api, so layouts are
// independently authored — and a toolkit can register its own sidebar against
// this exact surface later.
//
// Reactivity flows through getters: the host builds an object whose getters
// read its $state/$derived, so children reading `api.packages` stay reactive.

import { getContext, setContext } from "svelte";
import type { Component } from "svelte";
import type { NavLayout } from "$lib/bridge/nav.svelte";
import type { WorkbookEntry } from "$lib/bridge/package.svelte";
import type { RailPackage } from "$lib/components/Sidebar.svelte";

export type FolderBooks = WorkbookEntry[] | "loading" | undefined;

export interface SidebarApi {
  /** Active layout preset. */
  readonly layout: NavLayout;

  // ── Library — folders (expandable) + apps, drag-reorderable ──────────
  /** Packages in display order (drag-reorder applied). */
  readonly packages: RailPackage[];
  isExpanded(id: string): boolean;
  childrenOf(id: string): FolderBooks;
  toggleFolder(p: RailPackage): void;
  // drag state (reorder + move-into-folder)
  readonly dragId: string | null;
  readonly overId: string | null;
  readonly folderHotId: string | null;
  startDrag(id: string): void;
  dragOver(e: DragEvent, id: string): void;
  dragEnd(): void;
  folderOver(e: DragEvent, p: RailPackage): void;
  folderLeave(p: RailPackage): void;
  folderDrop(e: DragEvent, p: RailPackage): void;
  // open / context actions
  openApp(id: string): void;
  openWorkbook(path: string): void;
  packageContext(id: string, x: number, y: number): void;
  workbookContext(book: WorkbookEntry, e: MouseEvent): void;
  // the shared drag payload bus (apps/workbooks dragged to bookmarks etc.)
  dndStart(payload: { type: "app"; id: string; name: string } | { type: "workbook"; path: string; title: string }, e: DragEvent): void;
  dndEnd(): void;
}

const KEY = Symbol("wb.sidebar");

export function setSidebar(api: SidebarApi): void {
  setContext(KEY, api);
}

export function useSidebar(): SidebarApi {
  const api = getContext<SidebarApi | undefined>(KEY);
  if (!api) throw new Error("useSidebar() called outside a sidebar host");
  return api;
}

// Re-exported for layout/section components that render registry-style.
export type { Component, NavLayout, RailPackage, WorkbookEntry };

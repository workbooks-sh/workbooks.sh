/**
 * Bookmarks bridge — mirrors Rust `bookmarks.rs`.
 *
 * Quick-jump shortcuts to files anywhere across the workspace. Each
 * bookmark optionally claims one of ⌘1..⌘9; the global key handler
 * in +page.svelte resolves the slot to a path and asks the tabs
 * store to open it.
 */

import { invoke } from "@tauri-apps/api/core";

export interface Bookmark {
  id: string;
  title: string;
  path: string;
  /** 1..9 or null. */
  command_slot: number | null;
  created_at: number;
}

class BookmarksStore {
  bookmarks = $state<Bookmark[]>([]);
  loading = $state(false);
  lastError = $state<string | null>(null);

  #initStarted = false;

  async init() {
    if (this.#initStarted) return;
    this.#initStarted = true;
    await this.refresh();
  }

  dispose() {}

  async refresh() {
    this.loading = true;
    this.lastError = null;
    try {
      this.bookmarks = await invoke<Bookmark[]>("bookmark_list");
    } catch (e) {
      this.lastError = e instanceof Error ? e.message : String(e);
    } finally {
      this.loading = false;
    }
  }

  async create(
    title: string,
    path: string,
    command_slot: number | null = null,
  ): Promise<Bookmark> {
    const b = await invoke<Bookmark>("bookmark_create", {
      req: { title, path, command_slot },
    });
    await this.refresh();
    return b;
  }

  async update(id: string, title: string): Promise<void> {
    await invoke("bookmark_rename", { req: { id, title } });
    await this.refresh();
  }

  async delete(id: string): Promise<void> {
    await invoke("bookmark_delete", { id });
    await this.refresh();
  }

  async setSlot(id: string, slot: number | null): Promise<void> {
    await invoke("bookmark_set_slot", { req: { id, slot } });
    await this.refresh();
  }

  bySlot(slot: number): Bookmark | null {
    return this.bookmarks.find((b) => b.command_slot === slot) ?? null;
  }
}

export const bookmarks = new BookmarksStore();

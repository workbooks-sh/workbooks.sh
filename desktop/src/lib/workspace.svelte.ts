/**
 * workspace — the explorer root folder. The desktop app opens a folder (a
 * workbook package, or any dir of .org context) and shows it as an explorable
 * tree. The chosen root persists across restarts so the explorer is there by
 * default on next launch.
 */
import { store } from "./store.svelte";
import { pickFolderPath } from "./files";

const ROOT_KEY = "explorer:root";

class Workspace {
  root = $state<string | null>(null);
  #loaded = false;

  async init() {
    if (this.#loaded) return;
    this.#loaded = true;
    this.root = (await store.get<string>(ROOT_KEY)) ?? null;
  }

  async setRoot(path: string | null) {
    this.root = path;
    await store.set(ROOT_KEY, path);
  }

  /** Prompt for a folder and adopt it as the root. Returns the chosen path. */
  async openFolder(): Promise<string | null> {
    const path = await pickFolderPath();
    if (path) await this.setRoot(path);
    return path;
  }

  get name(): string {
    if (!this.root) return "No folder";
    return this.root.split(/[/\\]/).filter(Boolean).pop() ?? this.root;
  }
}

export const workspace = new Workspace();

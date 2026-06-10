/**
 * docIcons — one identity icon per document path, so the same thing
 * never wears three different icons (tab favicon vs bookmark tile vs
 * folder row — the Kanban bug).
 *
 * Sources register what they know: +page registers every app package's
 * workbook path with the package's stored icon at boot. Lookups fall
 * back to the surface's generic glyph (tab-kind icon, Cube) only when
 * the path has no registered identity.
 */
class DocIconRegistry {
  #byPath = $state<Record<string, string>>({});

  register(path: string, icon: string | undefined | null) {
    if (!path || !icon) return;
    if (this.#byPath[path] === icon) return;
    this.#byPath = { ...this.#byPath, [path]: icon };
  }

  iconFor(path: string): string | null {
    return this.#byPath[path] ?? null;
  }
}

export const docIcons = new DocIconRegistry();

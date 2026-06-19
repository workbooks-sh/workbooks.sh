/**
 * toolkitStore (mock) — models the org→workspace install lifecycle for the
 * Toolkit marketplace drawer.
 *
 * A toolkit moves through:
 *   available → (Add) → [installing for non-shipped] → in-org → (Add to
 *   workspace) → in-workspace
 *
 * Pre-shipped toolkits skip the download and land in-org instantly. State is
 * persisted to localStorage so the choices survive a reload. This is a
 * front-end mock of what the runtime install flow will do — no network.
 */

/** Toolkits that ship with the app — adding them to the org is instant (no
 *  download step), since the bits are already local. */
const SHIPPED = new Set<string>(["git", "sandbox", "ffmpeg", "icons"]);

/** Seeded as already plugged into the active workspace, so the marketplace
 *  shows a mix of states out of the box. */
const SEED_WORKSPACE = new Set<string>(["git"]);

export type ToolkitStatus = "available" | "installing" | "in-org" | "in-workspace";

const LS_KEY = "toolkits.install.v1";

function load(): { org: string[]; workspace: string[] } {
  if (typeof localStorage === "undefined") return { org: [], workspace: [] };
  try {
    const raw = localStorage.getItem(LS_KEY);
    if (raw) return JSON.parse(raw);
  } catch {
    /* corrupt / private mode — fall through to the seed */
  }
  return { org: [...SEED_WORKSPACE], workspace: [...SEED_WORKSPACE] };
}

class ToolkitStore {
  orgInstalled = $state<Set<string>>(new Set());
  workspaceAssigned = $state<Set<string>>(new Set());
  /** Transient — slugs mid-download. Not persisted. */
  installing = $state<Set<string>>(new Set());

  constructor() {
    const { org, workspace } = load();
    this.orgInstalled = new Set(org);
    this.workspaceAssigned = new Set(workspace);
  }

  isShipped(slug: string): boolean {
    return SHIPPED.has(slug);
  }

  statusOf(slug: string): ToolkitStatus {
    if (this.workspaceAssigned.has(slug)) return "in-workspace";
    if (this.orgInstalled.has(slug)) return "in-org";
    if (this.installing.has(slug)) return "installing";
    return "available";
  }

  #persist() {
    if (typeof localStorage === "undefined") return;
    try {
      localStorage.setItem(
        LS_KEY,
        JSON.stringify({
          org: [...this.orgInstalled],
          workspace: [...this.workspaceAssigned],
        }),
      );
    } catch {
      /* non-fatal */
    }
  }

  /** Add to the organization. Shipped toolkits land instantly; everything
   *  else simulates a brief download before becoming available org-wide. */
  addToOrg(slug: string) {
    if (this.orgInstalled.has(slug) || this.installing.has(slug)) return;
    if (this.isShipped(slug)) {
      this.orgInstalled = new Set(this.orgInstalled).add(slug);
      this.#persist();
      return;
    }
    this.installing = new Set(this.installing).add(slug);
    setTimeout(() => {
      const inst = new Set(this.installing);
      inst.delete(slug);
      this.installing = inst;
      this.orgInstalled = new Set(this.orgInstalled).add(slug);
      this.#persist();
    }, 900);
  }

  /** Plug an org toolkit into the active workspace. */
  addToWorkspace(slug: string) {
    if (!this.orgInstalled.has(slug)) return;
    this.workspaceAssigned = new Set(this.workspaceAssigned).add(slug);
    this.#persist();
  }
}

export const toolkitStore = new ToolkitStore();

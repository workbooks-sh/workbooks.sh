// Install-wizard store — drives the first-run / on-demand flow that gets the
// runtime engine running locally (a libkrun microVM via krunvm) or connects to
// a cloud engine. Offline-first: the wizard is ALWAYS skippable and never blocks
// the app. It is the UI over the native `engine_*` commands in daemon.rs.

import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { daemon } from "$lib/bridge/sidecar.svelte";

/** Native backend probe (matches machine.rs BackendStatus, camelCase serde). */
export interface BackendStatus {
  os: string;
  supported: boolean;
  krunvm: boolean;
  apfsVolume: boolean;
  brew: boolean;
}

/** Wizard steps. `closed` means not mounted; everything else is a visible pane. */
export type Step =
  | "closed"
  | "choose"
  | "local-detect"
  | "local-install"
  | "local-booting"
  | "cloud-form"
  | "cloud-connecting"
  | "done";

const DISMISS_KEY = "wb.engineWizardDismissed";

class WizardStore {
  step = $state<Step>("closed");
  backend = $state<BackendStatus | null>(null);
  /** Streaming setup log (krunvm install / image pull). Newest last. */
  log = $state<string[]>([]);
  error = $state<string | null>(null);
  busy = $state(false);

  // Cloud form fields.
  cloudUrl = $state("");
  cloudToken = $state("");

  #unlisten: UnlistenFn | null = null;

  /** Wire the `engine-setup` progress stream once. Idempotent. */
  async init() {
    if (this.#unlisten) return;
    this.#unlisten = await listen<string>("engine-setup", (e) => {
      // Keep the tail bounded so a chatty image pull can't grow unbounded.
      this.log = [...this.log, e.payload].slice(-200);
    });
  }

  /** Open the wizard at the choose step. */
  open() {
    this.error = null;
    this.log = [];
    this.step = "choose";
  }

  /** Close + remember the dismissal so we don't nag on every launch. */
  close() {
    this.step = "closed";
    try {
      localStorage.setItem(DISMISS_KEY, "1");
    } catch {
      /* private mode / no storage — fine, we just nag once more next time */
    }
  }

  /** First-run auto-open: only if the engine is down AND never dismissed. */
  maybeAutoOpen() {
    let dismissed = false;
    try {
      dismissed = localStorage.getItem(DISMISS_KEY) === "1";
    } catch {
      /* ignore */
    }
    if (dismissed) return;
    if (daemon.status.state === "ready") return;
    this.open();
  }

  // ---- local path ----------------------------------------------------------

  async chooseLocal() {
    this.error = null;
    this.step = "local-detect";
    try {
      const b = await invoke<BackendStatus>("engine_detect");
      this.backend = b;
      if (!b.supported) {
        // Non-mac: local engine isn't built yet — steer to cloud.
        this.error =
          "Running the engine locally isn't supported on this OS yet. Connect to a cloud engine instead.";
        this.step = "cloud-form";
        return;
      }
      if (!b.krunvm) {
        this.step = "local-install";
        return;
      }
      await this.bootLocal();
    } catch (e) {
      this.fail(e);
      this.step = "choose";
    }
  }

  async installBackend() {
    this.error = null;
    this.busy = true;
    this.log = [];
    try {
      const b = await invoke<BackendStatus>("engine_install_backend");
      this.backend = b;
      if (!b.krunvm) throw new Error("krunvm still missing after install.");
      await this.bootLocal();
    } catch (e) {
      this.fail(e);
    } finally {
      this.busy = false;
    }
  }

  async bootLocal() {
    this.error = null;
    this.log = [];
    this.step = "local-booting";
    try {
      await invoke("engine_boot_local");
      await daemon.init();
      // engine_boot_local already waited for discovery; reflect it.
      if (daemon.status.state === "ready" || daemon.status.url) {
        this.step = "done";
      } else {
        throw new Error(
          "The engine booted but didn't report healthy in time. Check the tray → engine logs, then retry.",
        );
      }
    } catch (e) {
      this.fail(e);
    }
  }

  // ---- cloud path ----------------------------------------------------------

  chooseCloud() {
    this.error = null;
    this.step = "cloud-form";
  }

  async connectCloud() {
    const url = this.cloudUrl.trim();
    if (!url) {
      this.error = "Enter the engine URL.";
      return;
    }
    this.error = null;
    this.busy = true;
    this.step = "cloud-connecting";
    try {
      await invoke("engine_connect_cloud", { url, token: this.cloudToken.trim() });
      await daemon.init();
      this.step = "done";
    } catch (e) {
      this.fail(e);
      this.step = "cloud-form";
    } finally {
      this.busy = false;
    }
  }

  // ---- helpers -------------------------------------------------------------

  retry() {
    this.error = null;
    this.step = "choose";
  }

  private fail(e: unknown) {
    this.error = e instanceof Error ? e.message : String(e);
  }

  destroy() {
    this.#unlisten?.();
    this.#unlisten = null;
  }
}

export const wizard = new WizardStore();

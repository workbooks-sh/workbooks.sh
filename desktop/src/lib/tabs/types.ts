// wb-i38o.8 — tab types mirror src-tauri/src/tabs.rs.

export type TabKind = "workbook" | "wavelet" | "org" | "code" | "text";

export interface Tab {
  id: string;
  path: string;
  title: string;
  kind: TabKind;
  dirty: boolean;
}

export interface TabsSnapshot {
  tabs: Tab[];
  active: string | null;
}

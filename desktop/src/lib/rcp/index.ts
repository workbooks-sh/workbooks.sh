// RCP — Runtime Connect Protocol client (spec: RUNTIME-CONNECT-PROTOCOL.org).
// Portable core (types/client/adapters) + the local Tauri provider singleton.
export * from "./types";
export * from "./adapters";
export { RcpClient } from "./client";
export { rcp } from "./providers/tauri-local";

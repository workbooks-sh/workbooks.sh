import { mount } from "svelte";
import App from "./App.svelte";
import "./app.css";
import { themes } from "$lib/theme.svelte";

// Apply persisted theme before first paint so the shell never flashes
// the default palette. Backed by the mock store today; swaps to
// tauri-store when the shell lands.
void themes.init();

const app = mount(App, { target: document.getElementById("app")! });

export default app;

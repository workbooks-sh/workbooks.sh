function initial() {
  if (typeof localStorage !== "undefined") {
    const s = localStorage.getItem("wb-theme");
    if (s) return s;
    if (matchMedia("(prefers-color-scheme: dark)").matches) return "dark";
  }
  return "light";
}
export const theme = $state({ mode: initial() });
export function applyTheme() { document.documentElement.dataset.theme = theme.mode; }
export function toggleTheme() {
  theme.mode = theme.mode === "dark" ? "light" : "dark";
  localStorage.setItem("wb-theme", theme.mode);
  applyTheme();
}

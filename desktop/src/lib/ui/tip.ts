// Reusable tooltip action — the same portaled ink chip the dock toolbar uses
// (`.dock-tip` is a global style defined in DockToolbar.svelte). Native `title`
// tooltips don't render reliably inside the desktop webview, so titlebar badges
// (search, nexus) use this for a consistent, always-visible tooltip — matching
// the Waldo tab.
export function tip(node: HTMLElement, label: string) {
  let el: HTMLDivElement | null = null;
  let text = label;

  function show() {
    if (!text || el) return;
    const r = node.getBoundingClientRect();
    el = document.createElement("div");
    el.className = "dock-tip";
    el.setAttribute("role", "tooltip");
    el.textContent = text;
    el.style.left = `${r.left + r.width / 2}px`;
    el.style.top = `${r.bottom + 8}px`;
    document.body.appendChild(el);
  }
  function hide() {
    el?.remove();
    el = null;
  }

  node.addEventListener("mouseenter", show);
  node.addEventListener("mouseleave", hide);
  node.addEventListener("focusin", show);
  node.addEventListener("focusout", hide);

  return {
    update(l: string) {
      text = l;
      if (el) el.textContent = l;
    },
    destroy() {
      hide();
      node.removeEventListener("mouseenter", show);
      node.removeEventListener("mouseleave", hide);
      node.removeEventListener("focusin", show);
      node.removeEventListener("focusout", hide);
    },
  };
}

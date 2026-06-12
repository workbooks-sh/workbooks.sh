/* ── mermaid, in house colors — shared by any learn page ────────────────────
   Pages opt in with <script type="module" src="learn-mermaid.js"></script>
   and author diagrams as <pre class="mermaid">…</pre>. Theme matches the
   brand: paper, ink strokes, mono type, bloom accent. */
import mermaid from "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs";

const ink = "#121316";
const paper = "#f7f6f1";
const bloom = "#13d943";

mermaid.initialize({
  startOnLoad: true,
  theme: "base",
  fontFamily: '"JetBrains Mono", monospace',
  themeVariables: {
    background: paper,
    primaryColor: "#ffffff",
    primaryBorderColor: ink,
    primaryTextColor: ink,
    secondaryColor: "#f2ddb0",
    tertiaryColor: "#eef0e9",
    lineColor: ink,
    textColor: ink,
    fontSize: "13px",
    nodeBorder: ink,
    clusterBkg: "#fbfaf6",
    clusterBorder: "rgba(18,19,22,.45)",
    edgeLabelBackground: paper,
    activationBorderColor: ink,
    actorBorder: ink,
    actorBkg: "#ffffff",
    signalColor: ink,
    signalTextColor: ink,
    labelBoxBkgColor: "#f2ddb0",
    noteBkgColor: "#f2ddb0",
    noteBorderColor: ink,
    taskBorderColor: ink,
    taskBkgColor: "#ffffff",
    taskTextColor: ink,
    activeTaskBorderColor: ink,
    activeTaskBkgColor: bloom,
    doneTaskBkgColor: "#d9dbd3",
    doneTaskBorderColor: ink,
    critBkgColor: "#f3c5a3",
    critBorderColor: ink,
    todayLineColor: bloom,
  },
});

// brand chrome around every rendered diagram
const style = document.createElement("style");
style.textContent = [
  "pre.mermaid { display: flex; justify-content: center; background: #fff;",
  "  border: 1.5px solid rgba(18,19,22,.35); border-radius: 12px; padding: 20px 14px; margin: 22px 0; overflow-x: auto; }",
  "pre.mermaid:not([data-processed]) { color: transparent; min-height: 120px; }",
  "pre.mermaid svg { max-width: 100%; }",
].join("\n");
document.head.appendChild(style);

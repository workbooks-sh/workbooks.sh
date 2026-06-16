# Component

Name: FolderIcon

## Controls

| prop  | type   | default | range/options |
|-------|--------|---------|---------------|
| icon  | text   | 📋      |               |
| color | color  | #9a9a9e |               |
| size  | range  | 56      | 20..120       |
| badge | toggle | true    |               |

## Source

```js
// Frameworkless render(el, props). The desktop ships this as a Svelte
// component; here it's plain JS so the story is portable + polyglot-by-
// construction (any language that compiles to a module exposing render).
export function render(el, props) {
  const { icon = "", color = "#9a9a9e", size = 56, badge = true } = props;
  const front = mix(color, "#ffffff", 0.2);
  const back  = mix(color, "#000000", 0.08);
  const edge  = mix(color, "#000000", 0.14);
  const s = size, h = s * 0.84;
  el.innerHTML = `
    <span style="position:relative;display:inline-grid;place-items:center;width:${s}px;height:${h}px">
      <svg viewBox="0 0 48 40" style="width:100%;height:100%;overflow:visible;filter:drop-shadow(0 1px 1.5px rgba(15,15,15,.16))">
        <path d="M3 7.5C3 5.6 4.6 4 6.5 4h10.2c.9 0 1.8.36 2.5 1l2.3 2.3c.66.63 1.55 1 2.47 1H41.5C43.4 8.3 45 9.9 45 11.8V32c0 1.9-1.6 3.5-3.5 3.5h-35C4.6 35.5 3 33.9 3 32z" fill="${back}"/>
        <path d="M3 15.5C3 13.6 4.6 12 6.5 12h35c1.9 0 3.5 1.6 3.5 3.5V32c0 1.9-1.6 3.5-3.5 3.5h-35C4.6 35.5 3 33.9 3 32z" fill="${front}" stroke="${edge}" stroke-width="0.5"/>
      </svg>
      ${badge && icon ? `<span style="position:absolute;left:2%;bottom:-3%;font-size:${s*0.46}px;line-height:1;filter:drop-shadow(0 0 1px rgba(255,255,255,.9)) drop-shadow(0 1px 1.5px rgba(0,0,0,.3))">${icon}</span>` : ""}
    </span>`;
}
function mix(a, b, t) {
  const pa = hex(a), pb = hex(b);
  return "#" + pa.map((v, i) => Math.round(v + (pb[i] - v) * t).toString(16).padStart(2, "0")).join("");
}
function hex(s) { s = s.replace("#", ""); return [0, 2, 4].map((i) => parseInt(s.slice(i, i + 2), 16)); }
```

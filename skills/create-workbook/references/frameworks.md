# Frameworks for a workbook

Pick deliberately and record the reason. The artifact is one self-contained
HTML file, so favor small footprints and explicit reactivity.

| Need | Choice | Why |
|---|---|---|
| Reactive UI, default | **Svelte 5 (runes) + Vite** | lander precedent; small bundle; fine-grained reactivity |
| Reactive, prefer JSX/signals | SolidJS + Vite | signals, tiny runtime |
| Light interactivity | vanilla + Vite | zero framework weight |
| Static data sheet | no framework | nothing to react to |

## Vite config invariant

Always set `base: './'` so the built artifact uses relative asset paths and a
dumb static server can serve `dist/`:

```js
import { defineConfig } from 'vite';
import { svelte } from '@sveltejs/vite-plugin-svelte';
export default defineConfig({ base: './', plugins: [svelte()] });
```

## Decision rule

Choose the **least** framework that covers the reactivity the workbook actually
needs. A heavier choice must justify itself in writing (bundle size vs feature).

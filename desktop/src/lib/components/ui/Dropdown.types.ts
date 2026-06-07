/**
 * Shared types for Dropdown.svelte — extracted because Svelte 5
 * components with `generics` can't `export type` from their <script>
 * block.
 */

export type DropdownItem<V> = {
  value: V;
  label: string;
  description?: string;
  icon?: typeof import("@lucide/svelte").Check;
  disabled?: boolean;
};

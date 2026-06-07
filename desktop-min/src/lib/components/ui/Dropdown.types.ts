import type { Component } from "svelte";

/** One option in a Dropdown. `icon` is a lucide component; `description`
 *  renders as a muted second line under the label. */
export interface DropdownItem<T extends string | number = string> {
  value: T;
  label: string;
  description?: string;
  icon?: Component;
  disabled?: boolean;
}

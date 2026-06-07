<!--
  CapIcon — small vintage-style SVG icons used in CapabilityCard tiles.
  All currentColor so they pick up the tile's text-* color.
-->
<script lang="ts">
  interface Props {
    name: "logo" | "megaphone" | "catalog" | "brief" | "palette" | "wires";
    size?: number;
  }
  let { name, size = 26 }: Props = $props();
</script>

{#if name === "logo"}
  <svg viewBox="0 0 32 32" width={size} height={size} fill="none" aria-hidden="true">
    <circle cx="16" cy="16" r="11" fill="currentColor" />
    <rect x="13" y="13" width="6" height="6" fill="#fff" transform="rotate(45 16 16)" />
  </svg>
{:else if name === "megaphone"}
  <svg viewBox="0 0 32 32" width={size} height={size} fill="none" aria-hidden="true">
    <path d="M5 13h6l12-6v18l-12-6H5z" fill="currentColor" />
    <path d="M11 13v6" stroke="#fff" stroke-width="2" stroke-linecap="round" />
    <circle cx="25" cy="16" r="1.5" fill="currentColor" />
  </svg>
{:else if name === "catalog"}
  <svg viewBox="0 0 32 32" width={size} height={size} fill="none" aria-hidden="true">
    <rect x="5" y="6" width="22" height="4" fill="currentColor" />
    <rect x="5" y="14" width="22" height="4" fill="currentColor" />
    <rect x="5" y="22" width="14" height="4" fill="currentColor" />
  </svg>
{:else if name === "brief"}
  <svg viewBox="0 0 32 32" width={size} height={size} fill="none" aria-hidden="true">
    <path d="M7 5h13l5 5v17H7z" fill="currentColor" />
    <path d="M20 5v5h5" stroke="#fff" stroke-width="1.5" fill="none" />
    <path d="M11 15h12M11 19h12M11 23h8" stroke="#fff" stroke-width="1.5" stroke-linecap="round" />
  </svg>
{:else if name === "palette"}
  <svg viewBox="0 0 32 32" width={size} height={size} fill="none" aria-hidden="true">
    <circle cx="16" cy="16" r="11" fill="currentColor" />
    <circle cx="11" cy="11" r="1.8" fill="#fff" />
    <circle cx="21" cy="11" r="1.8" fill="#fff" />
    <circle cx="22" cy="18" r="1.8" fill="#fff" />
    <circle cx="13" cy="22" r="1.8" fill="#fff" />
  </svg>
{:else if name === "wires"}
  <svg viewBox="0 0 32 32" width={size} height={size} fill="none" aria-hidden="true">
    <path d="M7 7l9 12 9-12" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" fill="none" />
    <circle cx="7" cy="7" r="2.5" fill="currentColor" />
    <circle cx="25" cy="7" r="2.5" fill="currentColor" />
    <circle cx="16" cy="22" r="2.5" fill="currentColor" />
  </svg>
{/if}

<script>let { kind = "do", children } = $props();</script>
<div class="rule {kind}">
  <span class="badge">{kind === "do" ? "DO" : "DON'T"}</span>
  <p>{@render children()}</p>
</div>
<style>
  .rule{display:flex;flex-direction:column;gap:.6rem;background:var(--card);border:1px solid var(--hair);
    border-radius:14px;padding:1.1rem 1.2rem}
  .badge{font-family:var(--mono);font-size:.62rem;font-weight:700;letter-spacing:.1em;padding:.18rem .55rem;border-radius:999px;align-self:flex-start}
  .do .badge{background:color-mix(in srgb,var(--green) 18%,var(--card));color:var(--green-ink)}
  .dont .badge{background:color-mix(in srgb,var(--rose) 18%,var(--card));color:var(--rose-text)}
  p{font-size:.9rem;color:var(--ink2);line-height:1.5}
  .rule :global(em){font-style:normal;color:var(--ink);font-weight:600}
</style>

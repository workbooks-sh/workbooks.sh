<script lang="ts">
  /**
   * DemoToolkitPanel — a placeholder dock panel shown only during onboarding
   * so the bench has real, toggleable toolkit shortcuts to demonstrate. Not
   * registered in the real app; OnboardingFlow registers + unregisters these.
   */
  import { Wrench } from "phosphor-svelte";
  let { title = "Toolkit" }: { title?: string } = $props();
</script>

<div class="demo-panel">
  <div class="badge"><Wrench size={18} weight="fill" /></div>
  <h2>{title}</h2>
  <p>A custom toolkit. Each one is a panel you can build and pin to the
     bench — click its icon up top to open or close it.</p>
  <span class="tag">Demo toolkit</span>
</div>

<style>
  .demo-panel {
    height: 100%;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 12px;
    padding: 28px 24px;
    text-align: center;
    color: var(--color-fg-muted);
  }
  .badge {
    display: grid;
    place-items: center;
    width: 44px;
    height: 44px;
    border-radius: 12px;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    color: var(--color-fg);
  }
  h2 {
    margin: 0;
    font-size: 1rem;
    font-weight: 600;
    color: var(--color-fg);
  }
  p {
    margin: 0;
    max-width: 30ch;
    font-size: 0.84rem;
    line-height: 1.45;
  }
  .tag {
    margin-top: 4px;
    font-family: var(--font-mono);
    font-size: 0.66rem;
    letter-spacing: 0.04em;
    text-transform: uppercase;
    color: var(--color-fg-subtle);
    border: 1px solid var(--color-border);
    border-radius: 999px;
    padding: 2px 9px;
  }
</style>

<script>
  // a workflow surface shows its RUNS by default; the editor (the node graph) is reached via "Edit flow".
  import WorkflowRuns from './WorkflowRuns.svelte'
  import WorkflowView from './WorkflowView.svelte'
  let { surfaceId } = $props()
  let mode = $state('runs')
</script>

{#if mode === 'edit'}
  <WorkflowView {surfaceId} onBack={() => (mode = 'runs')} />
{:else}
  <WorkflowRuns {surfaceId} onEdit={() => (mode = 'edit')} />
{/if}

<script>
  // React island: mounts the WorkOS User Management widget (a React component)
  // inside this Svelte component. Client-only — onMount never runs during SSR.
  import { onMount, onDestroy } from 'svelte';

  let { authToken } = $props();
  let el;
  let root;

  onMount(async () => {
    const React = (await import('react')).default;
    const { createRoot } = await import('react-dom/client');
    const { WorkOsWidgets, UsersManagement } = await import('@workos-inc/widgets');
    await import('@workos-inc/widgets/styles.css');

    root = createRoot(el);
    root.render(
      React.createElement(
        WorkOsWidgets,
        { authToken },
        React.createElement(UsersManagement, null)
      )
    );
  });

  onDestroy(() => {
    // defer so React isn't unmounted mid-render
    if (root) {
      const r = root;
      queueMicrotask(() => r.unmount());
    }
  });
</script>

<div bind:this={el}></div>

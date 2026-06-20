<script>
  let {
    open = false,
    title = 'Are you sure?',
    body = '',
    confirmLabel = 'Confirm',
    cancelLabel = 'Cancel',
    danger = false,
    onconfirm,
    oncancel
  } = $props();
</script>

{#if open}
  <div class="modal" onclick={(e) => { if (e.target === e.currentTarget) oncancel?.(); }}>
    <div class="sheet" style="width:440px">
      <h2>{title}</h2>
      {#if body}<p class="sub">{body}</p>{/if}
      <div class="foot" style="justify-content:flex-end">
        <div style="display:flex;gap:8px">
          <button class="btn" onclick={() => oncancel?.()}>{cancelLabel}</button>
          <button class="btn {danger ? 'danger' : 'primary'}" onclick={() => onconfirm?.()}>{confirmLabel}</button>
        </div>
      </div>
    </div>
  </div>
{/if}

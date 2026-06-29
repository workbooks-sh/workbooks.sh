<script>
  // A reusable vertical drag-to-resize handle. The parent owns the width state and updates it via onchange;
  // this just turns pointer drags into clamped width values. Works as a flex item (Code) or absolutely
  // positioned (Studio grid) — placement comes from the `class`/`style` props.
  let { value, min = 180, max = 560, dir = 'right', onchange, class: cls = '', style: stl = '' } = $props()
  let active = $state(false)
  let sx = 0, sw = 0
  function down(e) {
    active = true; sx = e.clientX; sw = value
    window.addEventListener('pointermove', move)
    window.addEventListener('pointerup', up)
    e.preventDefault()
  }
  function move(e) {
    const dx = (dir === 'left' ? -1 : 1) * (e.clientX - sx)
    onchange(Math.max(min, Math.min(max, Math.round(sw + dx))))
  }
  function up() {
    active = false
    window.removeEventListener('pointermove', move)
    window.removeEventListener('pointerup', up)
  }
</script>

<!-- svelte-ignore a11y_no_noninteractive_tabindex -->
<div role="separator" aria-orientation="vertical" tabindex="-1" onpointerdown={down}
  class="group/rh relative flex-none cursor-col-resize select-none {cls}" style="width:9px;{stl}" class:active>
  <div class="absolute inset-y-0 left-1/2 -translate-x-1/2 w-px transition-colors group-hover/rh:w-[2px]"
    style="background:{active ? 'var(--color-bloom)' : 'var(--color-line)'}"></div>
</div>

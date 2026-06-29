// Live ACTIVITY signal — a real in-flight counter the footer reads, so "running" only ever shows when
// something is genuinely executing (a shell command, a capability call). No fake processes; begin()/end()
// bracket real async work. `label` names what's running (the actual command), nothing invented.
export const activity = $state({ inflight: 0, label: null })

export function begin(label) { activity.inflight++; activity.label = label || activity.label }
export function end() { activity.inflight = Math.max(0, activity.inflight - 1); if (activity.inflight === 0) activity.label = null }

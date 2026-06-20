// The nexus list is now held client-side in $lib/nexusStore (stateful), so the
// detail page reads from the store rather than a server load — that's what lets
// a just-created nexus have a working detail page (no 404). The load just passes
// the id through.
export function load({ params }) {
  return { id: params.id };
}

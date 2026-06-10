export const build = $state({ shown: {}, done: false });
export function reveal(name) { build.shown = { ...build.shown, [name]: true }; }

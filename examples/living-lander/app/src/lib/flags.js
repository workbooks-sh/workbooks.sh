// Lander feature flags. Flip these to change which CTAs surface — no other
// edits needed; the nav/hero/get sections read straight from here.
//
//   desktopDownload — the "download for desktop" button. Kept on its own flag
//                     so the cloud launch can never silently drop the download
//                     path; turn it off only if desktop is ever retired.
//   cloud           — the hosted-nexus product. When true, a "sign in" link
//                     appears in the nav (→ dashboardUrl) and the hero offers
//                     "or run it in the cloud" alongside download.
//   dashboardUrl    — where "sign in" / cloud CTAs point.
export const flags = {
  desktopDownload: true,
  cloud: false,
  dashboardUrl: '/app',
};

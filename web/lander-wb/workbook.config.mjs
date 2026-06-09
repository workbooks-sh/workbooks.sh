// workbooks.sh landing page — built as a Workbook (dogfooding the format).
// SPA shape, but it calls zero wb.* WASM APIs, so wasmVariant "none"
// drops the artifact from ~8 MB to ~150 KB.

export default {
  name: "Workbooks",
  slug: "workbooks",
  entry: "index.html",
  type: "spa",
  wasmVariant: "none",
  author: "Workbooks",
  description: "Build apps you actually own. A free desktop app for making your own software with AI.",
  // This page is the public lander; the install toast that points users
  // at workbooks.sh doesn't apply here.
  installToast: { enabled: false },
  save: { enabled: false },
};

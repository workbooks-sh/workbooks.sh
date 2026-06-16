// Work-format → HTML pipeline.
//
// The kernel now emits `work-*` HTML directly (work::render_work): status
// pills, tag chips and property drawers are each element's own shadow-DOM
// concern, not post-hoc regex injection. So this is just: call the kernel
// renderer, hand back the `work-*` HTML for the caller to mount. The former
// transforms.ts regex chrome (injectHeadingChrome / transformGapComments) is
// retired with org. See docs/WORK-FORMAT.md.

import { getOql } from "./oql";

export async function renderOrg(source: string): Promise<string> {
  const oql = await getOql();
  return oql.renderHtml(source);
}

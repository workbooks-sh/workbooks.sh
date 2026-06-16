import { describe, it, expect } from "vitest";
import { splitOrg, renderMode } from "./messageRender";

// Adversarial coverage for the in-chat render parser. The agent's output is UNTRUSTED;
// splitOrg is the seam that turns it into prose + component segments. The render contract
// is "props/body are DATA forwarded to <work-gen-block> as attributes/textContent, never
// {@html}". So the parser must: never throw, never execute/strip injection (preserve it as
// data so the downstream sink can neutralize it), tolerate malformed/unknown blocks, and
// not blow up on hostile input. These assert behavior — they go red if the parser breaks.

const M = "#+RENDER: org\n";

describe("renderMode", () => {
  it("only the leading marker (within the first line) opts into org", () => {
    expect(renderMode(M + "hi")).toBe("org");
    expect(renderMode("just prose, no marker")).toBe("plain");
  });

  it("a marker buried past the first 64 chars does NOT flip to org (no late-marker surprise)", () => {
    const buried = "x".repeat(80) + "\n#+RENDER: org\n";
    expect(renderMode(buried)).toBe("plain");
  });
});

describe("splitOrg — resilience", () => {
  it("an UNKNOWN component type is preserved verbatim (renderer falls back; parser must not reject)", () => {
    const segs = splitOrg(M + "#+begin_src component :type quokka-mystery-widget\nbody\n#+end_src\n");
    const comp = segs.find((s) => s.kind === "component");
    expect(comp).toBeDefined();
    expect(comp && comp.kind === "component" && comp.type).toBe("quokka-mystery-widget");
  });

  it("a missing :type defaults to callout (never an empty/undefined tag)", () => {
    const segs = splitOrg(M + "#+begin_src component :tone info\nhello\n#+end_src\n");
    const comp = segs.find((s) => s.kind === "component");
    expect(comp && comp.kind === "component" && comp.type).toBe("callout");
  });

  it("a malformed block (no #+end_src) does NOT throw and is left as prose, not a component", () => {
    const segs = splitOrg(M + "#+begin_src component :type kv\nnever closed...");
    expect(segs.every((s) => s.kind === "org")).toBe(true);
  });

  it("a marker-only message yields no crash (empty org), not a throw", () => {
    expect(() => splitOrg(M)).not.toThrow();
    expect(splitOrg(M + "  ")).toEqual([]);
  });
});

describe("splitOrg — injection is captured as DATA, never executed or stripped", () => {
  it("a </script> + tags in the body survive verbatim (the sink neutralizes; the parser must not mangle)", () => {
    const evil = "</script><img src=x onerror=alert(1)>";
    const segs = splitOrg(M + `#+begin_src component :type callout\n${evil}\n#+end_src\n`);
    const comp = segs.find((s) => s.kind === "component");
    expect(comp && comp.kind === "component" && comp.body).toBe(evil);
  });

  it("injection inside a prop value is captured as a plain string prop", () => {
    const segs = splitOrg(M + `#+begin_src component :type callout :title <script>x</script>\nb\n#+end_src\n`);
    const comp = segs.find((s) => s.kind === "component");
    expect(comp && comp.kind === "component" && comp.props.title).toContain("<script>");
  });
});

describe("splitOrg — hostile input does not hang (ReDoS-shaped)", () => {
  it("many unterminated begin_src lines parse quickly and finish", () => {
    const hostile = M + "#+begin_src component :type kv\n".repeat(5000);
    const t0 = Date.now();
    const segs = splitOrg(hostile);
    expect(Date.now() - t0).toBeLessThan(2000); // must not catastrophically backtrack
    expect(Array.isArray(segs)).toBe(true);
  });

  it("interleaved prose and multiple real components keep order", () => {
    const text =
      M +
      "intro\n" +
      "#+begin_src component :type callout\none\n#+end_src\n" +
      "middle\n" +
      "#+begin_src component :type kv\ntwo\n#+end_src\n" +
      "outro";
    const kinds = splitOrg(text).map((s) => s.kind);
    expect(kinds).toEqual(["org", "component", "org", "component", "org"]);
  });
});

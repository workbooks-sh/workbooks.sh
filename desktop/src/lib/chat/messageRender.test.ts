import { describe, it, expect } from "vitest";
import { splitComponents, type ComponentSegment } from "./messageRender";

// Adversarial coverage for the in-chat render parser. The agent's output is UNTRUSTED;
// splitComponents is the seam that turns it into prose + inline `<work-*>` element
// segments. The render contract is "attrs/body are DATA forwarded to the real custom
// element as attributes/textContent, never {@html} of raw model output". So the parser
// must: never throw, never execute/strip injection (preserve it as data so the downstream
// sink can neutralize it), tolerate malformed/unknown tags, and not blow up on hostile
// input. These assert behavior — they go red if the parser breaks.

const comp = (segs: ReturnType<typeof splitComponents>) =>
  segs.find((s): s is ComponentSegment => s.kind === "component");

describe("splitComponents — basics", () => {
  it("plain prose with no element stays a single text segment", () => {
    const segs = splitComponents("just prose, no element");
    expect(segs).toEqual([{ kind: "text", source: "just prose, no element" }]);
  });

  it("an UNKNOWN work-* tag is preserved verbatim (renderer falls back; parser must not reject)", () => {
    const c = comp(splitComponents("<work-quokka-mystery-widget>body</work-quokka-mystery-widget>"));
    expect(c).toBeDefined();
    expect(c?.tag).toBe("work-quokka-mystery-widget");
    expect(c?.body).toBe("body");
  });

  it("a self-closing element parses with empty body", () => {
    const c = comp(splitComponents('<work-spark value="42" />'));
    expect(c?.tag).toBe("work-spark");
    expect(c?.attrs.value).toBe("42");
    expect(c?.body).toBe("");
  });

  it("a malformed element (no closing tag) is NOT a component and does not throw", () => {
    const segs = splitComponents("<work-kv>never closed...");
    expect(segs.every((s) => s.kind === "text")).toBe(true);
  });
});

describe("splitComponents — injection is captured as DATA, never executed or stripped", () => {
  it("a </script> + tags in the body survive verbatim (the sink neutralizes; the parser must not mangle)", () => {
    const evil = "</script><img src=x onerror=alert(1)>";
    const c = comp(splitComponents(`<work-callout>${evil}</work-callout>`));
    expect(c?.body).toBe(evil);
  });

  it("injection inside an attribute value is captured as a plain string attr", () => {
    const c = comp(splitComponents(`<work-callout title="<script>x</script>">b</work-callout>`));
    expect(c?.attrs.title).toContain("<script>");
  });
});

describe("splitComponents — hostile input does not hang (ReDoS-shaped)", () => {
  it("many unterminated open tags parse quickly and finish", () => {
    const hostile = "<work-kv>\n".repeat(5000);
    const t0 = Date.now();
    const segs = splitComponents(hostile);
    expect(Date.now() - t0).toBeLessThan(2000); // must not catastrophically backtrack
    expect(Array.isArray(segs)).toBe(true);
  });

  it("interleaved prose and multiple real components keep order", () => {
    const text =
      "intro\n" +
      "<work-callout>one</work-callout>\n" +
      "middle\n" +
      "<work-kv>two</work-kv>\n" +
      "outro";
    const kinds = splitComponents(text).map((s) => s.kind);
    expect(kinds).toEqual(["text", "component", "text", "component", "text"]);
  });
});

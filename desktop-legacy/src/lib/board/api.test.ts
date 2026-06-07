// wb-i38o.33.6 — unit tests for the board's data layer.
//
// Pure-TS land: no Svelte runtime, no Tauri runtime. The groupByStatus
// helper is the load-bearing one — column ordering + dropping no-state
// rows have to be right or the board renders nonsense.

import { describe, expect, it } from "vitest";
import { groupBy, groupByStatus } from "./api";
import type { BoardHeadline } from "./types";

function h(overrides: Partial<BoardHeadline>): BoardHeadline {
  return {
    id: null,
    title: "headline",
    state: null,
    priority: null,
    level: 1,
    tags: [],
    ...overrides,
  };
}

describe("groupByStatus", () => {
  it("returns empty when given no headlines and no starter columns", () => {
    expect(groupByStatus([])).toEqual([]);
  });

  it("groups one headline into its column", () => {
    const cols = groupByStatus([h({ id: "a", state: "TODO" })]);
    expect(cols).toHaveLength(1);
    expect(cols[0].state).toBe("TODO");
    expect(cols[0].cards).toHaveLength(1);
    expect(cols[0].cards[0].id).toBe("a");
    expect(cols[0].cards[0].cardId).toBe("a"); // matches headline id when set
  });

  it("assigns synthetic cardId when headline has no :ID:", () => {
    const cols = groupByStatus([h({ id: null, title: "no-id", state: "TODO" })]);
    expect(cols[0].cards[0].cardId).toMatch(/^_synth_/);
  });

  it("preserves canonical GTD order for matched columns", () => {
    const cols = groupByStatus([
      h({ id: "d", state: "DONE" }),
      h({ id: "a", state: "TODO" }),
      h({ id: "b", state: "DOING" }),
    ]);
    expect(cols.map((c) => c.state)).toEqual(["TODO", "DOING", "DONE"]);
  });

  it("places custom (non-canonical) states alpha-sorted after the canonical block", () => {
    const cols = groupByStatus([
      h({ id: "1", state: "TODO" }),
      h({ id: "2", state: "MAYBE" }),
      h({ id: "3", state: "AWAITS_LEGAL" }),
    ]);
    expect(cols.map((c) => c.state)).toEqual(["TODO", "AWAITS_LEGAL", "MAYBE"]);
  });

  it("drops headlines with no state (defensive — loose queries)", () => {
    const cols = groupByStatus([
      h({ id: "kept", state: "TODO" }),
      h({ id: "dropped", state: null }),
    ]);
    expect(cols).toHaveLength(1);
    expect(cols[0].cards).toHaveLength(1);
    expect(cols[0].cards[0].id).toBe("kept");
  });

  it("preserves card order within a column", () => {
    const cols = groupByStatus([
      h({ id: "1", state: "TODO" }),
      h({ id: "2", state: "TODO" }),
      h({ id: "3", state: "TODO" }),
    ]);
    expect(cols[0].cards.map((c) => c.id)).toEqual(["1", "2", "3"]);
  });

  it("includes starter columns even when they have zero cards", () => {
    const cols = groupByStatus([h({ id: "1", state: "TODO" })], [
      "TODO",
      "DOING",
      "DONE",
    ]);
    expect(cols.map((c) => c.state)).toEqual(["TODO", "DOING", "DONE"]);
    expect(cols[1].cards).toEqual([]);
    expect(cols[2].cards).toEqual([]);
  });

  it("starter columns don't duplicate when same state also appears in headlines", () => {
    const cols = groupByStatus(
      [h({ id: "1", state: "TODO" }), h({ id: "2", state: "TODO" })],
      ["TODO", "DOING"],
    );
    expect(cols.map((c) => c.state)).toEqual(["TODO", "DOING"]);
    expect(cols[0].cards).toHaveLength(2);
  });
});

describe("groupBy (assigned mode — wb-8fcg)", () => {
  it("groups by :ASSIGNED_AGENT: with pinned agent columns", () => {
    const cols = groupBy(
      [
        h({ id: "1", state: "TODO", assigned: "workhorse" }),
        h({ id: "2", state: "NEXT", assigned: "wavelet-director" }),
        h({ id: "3", state: "TODO", assigned: "workhorse" }),
      ],
      "assigned",
      ["workhorse", "wavelet-director", "brand-research", "(unassigned)"],
    );

    // All pinned columns appear in order, even empty ones.
    expect(cols.map((c) => c.state)).toEqual([
      "workhorse",
      "wavelet-director",
      "brand-research",
      "(unassigned)",
    ]);
    expect(cols[0].cards.map((c) => c.id)).toEqual(["1", "3"]);
    expect(cols[1].cards.map((c) => c.id)).toEqual(["2"]);
    expect(cols[2].cards).toEqual([]); // empty column for an agent with no tasks
  });

  it("headlines without :ASSIGNED_AGENT: land in (unassigned)", () => {
    const cols = groupBy(
      [
        h({ id: "1", state: "TODO" }), // no assigned
        h({ id: "2", state: "NEXT", assigned: "workhorse" }),
      ],
      "assigned",
      ["workhorse", "(unassigned)"],
    );

    const unassigned = cols.find((c) => c.state === "(unassigned)");
    expect(unassigned).toBeDefined();
    expect(unassigned?.cards.map((c) => c.id)).toEqual(["1"]);
  });

  it("status mode still works via groupBy(kind='status')", () => {
    const cols = groupBy(
      [h({ id: "a", state: "TODO" })],
      "status",
      ["TODO", "DOING", "DONE"],
    );
    expect(cols.map((c) => c.state)).toEqual(["TODO", "DOING", "DONE"]);
    expect(cols[0].cards).toHaveLength(1);
  });

  it("priority mode uses the priority cookie letter", () => {
    const cols = groupBy(
      [
        h({ id: "a", state: "TODO", priority: "A" }),
        h({ id: "b", state: "TODO", priority: "C" }),
        h({ id: "c", state: "TODO" }), // no priority → "(none)"
      ],
      "priority",
      [],
    );
    expect(cols.find((c) => c.state === "A")?.cards.map((c) => c.id)).toEqual(["a"]);
    expect(cols.find((c) => c.state === "C")?.cards.map((c) => c.id)).toEqual(["b"]);
    expect(cols.find((c) => c.state === "(none)")?.cards.map((c) => c.id)).toEqual(["c"]);
  });
});

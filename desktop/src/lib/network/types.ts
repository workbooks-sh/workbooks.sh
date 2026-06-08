/**
 * UI types for the Network surface — what the components render against.
 *
 * These mirror the broker/desktop wire shapes from client.ts (handles,
 * RIDs, etc.) but are the shape components actually accept as props.
 * The bridge code maps wire → UI; UI components don't talk to the
 * Broker directly, they take these structs from their parents.
 *
 * Previously these lived in `demo/data.ts` alongside fixture constants
 * named `ME`, `INBOX`, etc. The fixtures got removed because they were
 * leaking into production UI (synthesized "verified · real name"
 * badges, fake "upstream changes" pills based on string-matching
 * artifact titles, etc.) — the audit flagged ~6 such cases. Real data
 * now flows from `client.ts` via the per-tab `loadXxx()` calls.
 */

/** A person (friend, follower, network member, share author). */
export interface Person {
  handle: string;
  displayName: string;
  /** Emoji glyph OR data URL. */
  avatar: string;
  bio: string;
  did: string;
  /** True iff the identity is WorkOS-bound with a real-name on file. */
  verified: boolean;
  publishedCount: number;
  networkIds: string[];
}

export type NetworkKind = "personal" | "project" | "org";
export type NetworkJoin = "open" | "request" | "invite";

export interface Network {
  id: string;
  name: string;
  blurb: string;
  kind: NetworkKind;
  join: NetworkJoin;
  memberCount: number;
  /** Up to 5, for the rail preview. */
  memberHandles: string[];
  createdAt: string;
}

export type ArtifactKind = "workbook" | "agent" | "plugin" | "skill";

/** A workbook (or agent/plugin/skill) referenced in the UI — the shape
 *  ShareCard, PreviewPane, and the lineage tree all render against. */
export interface Artifact {
  id: string;
  kind: ArtifactKind;
  title: string;
  blurb: string;
  authorHandle: string;
  thumbnailEmoji: string;
  verified: boolean;
}

export type ActivityKind = "published" | "updated" | "forked" | "joined";

export interface Reaction {
  emoji: string;
  count: number;
  reactedByMe?: boolean;
}

export interface Activity {
  id: string;
  kind: ActivityKind;
  authorHandle: string;
  networkId: string;
  artifact: Artifact;
  /** Human-relative timestamp string. */
  ts: string;
  reactions: Reaction[];
}

export interface Share {
  id: string;
  /** Sender handle. */
  from: string;
  /** Recipient handle. */
  to: string;
  artifact: Artifact;
  message?: string;
  state: "pending" | "accepted" | "declined";
  /** Human-relative timestamp string. */
  ts: string;
}

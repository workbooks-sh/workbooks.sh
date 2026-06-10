<script lang="ts">
  /**
   * ProvenanceBadge — C2PA + Radicle verification state, person-level
   * when used inline next to a handle, or artifact-level when used on a
   * workbook tile. Always shows the text label (not just an icon) so the
   * meaning reads at a glance; the tooltip explains why.
   */
  import { ShieldCheck, ShieldWarning as ShieldAlert, ShieldSlash as ShieldOff } from "phosphor-svelte";

  type State = "verified" | "unverified" | "modified";
  type Subject = "person" | "artifact";

  let {
    state,
    by,
    realName = null,
    subject = "person",
    compact = false,
  }: {
    state: State;
    by?: string;
    realName?: string | null;
    subject?: Subject;
    compact?: boolean;
  } = $props();

  const Icon = $derived(
    state === "verified" ? ShieldCheck : state === "modified" ? ShieldAlert : ShieldOff,
  );

  // "Verified · real name" gets a gold-tone variant — visually distinct
  // from plain handle-verified emerald, because it signals an additional
  // off-platform check (WorkOS confirms a legal-ish name). wb-u2o0.5.4.
  const isVerifiedRealName = $derived(state === "verified" && !!realName);

  // Short label — always present even in compact mode (compact just
  // tightens padding, keeps the word so meaning isn't icon-only).
  const label = $derived(
    state === "verified"
      ? realName
        ? `verified · ${realName}`
        : "verified"
      : state === "modified"
        ? "modified after publish"
        : "unverified",
  );

  // Descriptive tooltip — explains WHY the badge reads the way it does,
  // adapted to whether we're talking about a person or an artifact.
  const tooltip = $derived.by(() => {
    if (subject === "person") {
      if (state === "verified") {
        return realName
          ? `Verified identity — @${by ?? "this person"} signed into Workbooks with "${realName}" on file as their real name. Everything they publish is signed by their identity key.`
          : `Verified handle — @${by ?? "this person"}'s identity key has been confirmed. No real name on file, but signatures match.`;
      }
      return `Unverified — @${by ?? "this person"} hasn't bound their handle to a real-name account. Their posts are still signed cryptographically; we just haven't confirmed who they are off-platform.`;
    }
    // artifact
    if (state === "verified") {
      return `Verified — this workbook's bytes match the snapshot the publisher signed at publish time. The signature checks out against ${by ? `@${by}'s` : "the publisher's"} identity key.`;
    }
    if (state === "modified") {
      return `Modified after publication — the bytes you're seeing don't match the snapshot the publisher signed. This may be benign (a re-export) or it may be tampered. Treat with care.`;
    }
    return `Unverified — no valid signature was found for this workbook. We can't confirm it came from the handle it claims to.`;
  });
</script>

<span class="badge {state}" class:compact class:verified-real-name={isVerifiedRealName} title={tooltip}>
  <Icon size={compact ? 10 : 11} weight="fill" />
  <span>{label}</span>
</span>

<style>
  .badge {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 2.5px 8px 2.5px 7px;
    border-radius: 999px;
    font-size: 0.7rem;
    font-weight: 600;
    letter-spacing: -0.005em;
    line-height: 1;
    border: 1px solid transparent;
    cursor: help;
  }
  .badge.compact {
    padding: 2px 7px 2px 6px;
    font-size: 0.66rem;
  }
  .badge.verified {
    color: rgb(20, 110, 70);
    background: rgba(34, 160, 105, 0.10);
    border-color: rgba(34, 160, 105, 0.22);
  }
  /* Gold variant overrides emerald when the real name is on file.
     Slightly higher contrast borders + a subtle gradient to read
     as "premium" without being garish. */
  .badge.verified.verified-real-name {
    color: rgb(133, 90, 5);
    background:
      linear-gradient(135deg, rgba(212, 165, 50, 0.16), rgba(212, 165, 50, 0.08));
    border-color: rgba(184, 140, 30, 0.40);
  }
  .badge.modified {
    color: rgb(150, 95, 10);
    background: rgba(225, 145, 30, 0.10);
    border-color: rgba(225, 145, 30, 0.22);
  }
  .badge.unverified {
    color: var(--color-fg-muted);
    background: var(--color-surface-soft);
    border-color: var(--color-border);
  }

  @media (prefers-color-scheme: dark) {
    .badge.verified {
      color: rgb(120, 220, 165);
      background: rgba(34, 160, 105, 0.16);
      border-color: rgba(34, 160, 105, 0.32);
    }
    .badge.verified.verified-real-name {
      color: rgb(240, 200, 110);
      background:
        linear-gradient(135deg, rgba(212, 165, 50, 0.22), rgba(212, 165, 50, 0.12));
      border-color: rgba(212, 165, 50, 0.50);
    }
    .badge.modified {
      color: rgb(245, 195, 110);
      background: rgba(225, 145, 30, 0.16);
      border-color: rgba(225, 145, 30, 0.32);
    }
  }
</style>

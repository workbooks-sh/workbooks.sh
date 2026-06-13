<script lang="ts">
  /**
   * GetStarted — the Network page's "you have no feed yet" landing.
   *
   * Replaces the generic EmptyState that used to live under the "All"
   * tab. This is the front door to Network for everyone who hasn't
   * bound an identity yet AND for signed-in users who haven't built
   * up a feed — so it has to set expectations (peer-to-peer, no
   * central authority) without reading as "broken / nothing here."
   *
   * Visual model:
   *   - Workbooks monogram as the hero glyph.
   *   - Three colored orbs floating in the page periphery (top-left,
   *     middle-right, bottom-left) on a gentle drift animation. Their
   *     gradients come from the same shaded-sphere recipe used in
   *     EmptyState — kept in sync so the visual language is one
   *     family across the app — but they're MUCH larger and sit in
   *     the background plate, not the foreground cluster.
   *   - Three value-prop cards beneath the hero, each with a small
   *     inline-SVG illustration. Monochromatic on chrome per the
   *     project rule; only the floating orbs carry color.
   */
  import { auth } from "$lib/auth/store.svelte";

  let {
    onconnect,
    oncreate,
    bound = false,
  }: {
    /** Open ConnectFlow (bind a Network identity via Workhorse). */
    onconnect: () => void;
    /** Open JoinOrCreateModal (start or join a network). */
    oncreate: () => void;
    /** Has the user already bound an identity? When true the primary
     *  CTA flips to "Create or join a network" instead of "Connect". */
    bound?: boolean;
  } = $props();

  // Display string for the welcome line. Use the first part of the
  // email as a friendly handle stand-in until the user binds a real
  // network handle via ConnectFlow.
  const greeting = $derived(
    auth.user?.displayName ?? auth.user?.email?.split("@")[0] ?? null,
  );

  // Three value props. Each carries a key, a heading, a single
  // sentence (the WHY, not the WHAT), and a SVG illustration that
  // visualises the concept at-a-glance.
  type ValueProp = { key: string; title: string; body: string };
  const valueProps: ValueProp[] = [
    {
      key: "share",
      title: "Ship work as a single file",
      body: "Workbooks, plugins, and skills travel as one HTML file that opens anywhere — no install, no account on the receiving end.",
    },
    {
      key: "p2p",
      title: "Peer-to-peer by design",
      body: "There's no central server holding your work hostage. You connect directly to the people you've added, and your network is yours.",
    },
    {
      key: "people",
      title: "Friends, groups, organisations",
      body: "Invite the handful of people who actually matter, group what you share, or stand up an org for a team.",
    },
  ];
</script>

<div class="page" aria-label="Welcome to Workbooks Network">
  <!-- Peripheral orbs. aria-hidden because they're pure decoration. -->
  <div class="orbs" aria-hidden="true">
    <span class="orb orb-a" style:--hue="340" style:--sat="65%"></span>
    <span class="orb orb-b" style:--hue="190" style:--sat="65%"></span>
    <span class="orb orb-c" style:--hue="35" style:--sat="68%"></span>
    <span class="orb orb-d" style:--hue="270" style:--sat="60%"></span>
  </div>

  <div class="content">
    <header class="hero">
      <div class="logo" aria-hidden="true">
        <!-- Workbooks monogram — the same path the desktop's
             favicon/app-icon uses. Currentcolor so it tints with the
             page foreground. -->
        <svg viewBox="0 0 113.444 65.6002" width="62" height="36">
          <path
            fill="currentColor"
            d="M48.271 0.137041C54.0348 -0.0424459 59.4862 -0.100239 65.2392 0.307556C65.5299 10.0796 65.1746 19.9621 65.4617 29.7381C65.4868 30.5677 65.8708 31.142 66.3912 31.7433C72.1083 33.4642 84.7519 13.8452 90.9211 11.7402C93.9071 12.344 100.087 19.9987 102.273 22.457C98.7305 28.4167 83.2732 40.6907 81.3819 45.0034C81.3999 46.2868 81.4501 46.3256 82.1571 47.442C83.7075 48.637 108.252 47.9876 113.133 48.4643C113.57 53.985 113.431 59.865 113.391 65.4284C101.67 65.4485 86.6791 66.781 76.4724 61.6904C68.0493 57.5274 61.6503 50.1601 58.7039 41.2382C57.9394 38.5857 57.3868 36.1501 56.7802 33.4675C55.5995 38.7002 54.6772 42.9878 51.9209 47.7051C39.8045 68.4416 20.2283 65.4557 0.0653694 65.3889C-0.0584465 59.646 -0.00641725 53.9006 0.221835 48.1606C5.51182 48.1355 28.4253 48.7415 31.6987 47.27C31.862 46.8967 31.9051 46.8482 31.9866 46.4038C32.6717 42.6809 14.5579 27.3487 11.6183 22.8379L11.3728 22.4563C13.1769 19.9072 19.3469 13.0734 22.063 11.7735C25.7911 11.2107 40.0016 29.8303 44.4561 31.6887C45.845 32.2681 46.0675 32.2311 47.2913 31.7505C48.6658 29.7977 48.2064 22.821 48.2172 20.1527L48.271 0.137041Z"
          />
        </svg>
      </div>

      {#if greeting}
        <p class="kicker">Welcome, {greeting}.</p>
      {/if}
      <h1 class="headline">
        Your peer-to-peer network for sharing workbooks.
      </h1>
      <p class="lede">
        Connect to the people you trust, share workbooks and plugins
        directly with them, and keep ownership of your work.
      </p>

      <div class="cta-row">
        {#if bound}
          <button type="button" class="primary" onclick={oncreate}>
            Create or join a network
          </button>
          <button type="button" class="secondary" onclick={onconnect}>
            Manage identity
          </button>
        {:else}
          <button type="button" class="primary" onclick={onconnect}>
            Set up your Network identity
          </button>
          <button type="button" class="secondary" onclick={oncreate}>
            Invite a friend
          </button>
        {/if}
      </div>
    </header>

    <ul class="cards">
      {#each valueProps as p (p.key)}
        <li class="card">
          <div class="illus" aria-hidden="true">
            {#if p.key === "share"}
              <!-- A workbook (rounded square) with three arcs reaching
                   out to peer dots. Reads as "one file, many people." -->
              <svg viewBox="0 0 120 80" width="100%" height="100%">
                <rect x="48" y="26" width="24" height="30" rx="3"
                  fill="none" stroke="currentColor" stroke-width="1.4"/>
                <line x1="53" y1="34" x2="67" y2="34" stroke="currentColor" stroke-width="1"/>
                <line x1="53" y1="40" x2="67" y2="40" stroke="currentColor" stroke-width="1"/>
                <line x1="53" y1="46" x2="63" y2="46" stroke="currentColor" stroke-width="1"/>
                <circle cx="18" cy="20" r="4" fill="currentColor" opacity="0.85"/>
                <circle cx="102" cy="20" r="4" fill="currentColor" opacity="0.85"/>
                <circle cx="18" cy="62" r="4" fill="currentColor" opacity="0.85"/>
                <circle cx="102" cy="62" r="4" fill="currentColor" opacity="0.85"/>
                <path d="M48 36 Q35 28 22 22"
                  fill="none" stroke="currentColor" stroke-width="1" opacity="0.45"/>
                <path d="M72 36 Q85 28 98 22"
                  fill="none" stroke="currentColor" stroke-width="1" opacity="0.45"/>
                <path d="M48 48 Q35 56 22 60"
                  fill="none" stroke="currentColor" stroke-width="1" opacity="0.45"/>
                <path d="M72 48 Q85 56 98 60"
                  fill="none" stroke="currentColor" stroke-width="1" opacity="0.45"/>
              </svg>
            {:else if p.key === "p2p"}
              <!-- Mesh: peers connected to each other with no centre.
                   Crucially NO node sits in the middle — that's the
                   "no central authority" point. -->
              <svg viewBox="0 0 120 80" width="100%" height="100%">
                <line x1="20" y1="20" x2="100" y2="20"
                  stroke="currentColor" stroke-width="1" opacity="0.35"/>
                <line x1="20" y1="60" x2="100" y2="60"
                  stroke="currentColor" stroke-width="1" opacity="0.35"/>
                <line x1="20" y1="20" x2="20" y2="60"
                  stroke="currentColor" stroke-width="1" opacity="0.35"/>
                <line x1="100" y1="20" x2="100" y2="60"
                  stroke="currentColor" stroke-width="1" opacity="0.35"/>
                <line x1="20" y1="20" x2="100" y2="60"
                  stroke="currentColor" stroke-width="1" opacity="0.35"/>
                <line x1="100" y1="20" x2="20" y2="60"
                  stroke="currentColor" stroke-width="1" opacity="0.35"/>
                <line x1="60" y1="14" x2="60" y2="66"
                  stroke="currentColor" stroke-width="1" opacity="0.35"
                  stroke-dasharray="2 3"/>
                <circle cx="20" cy="20" r="5" fill="currentColor"/>
                <circle cx="100" cy="20" r="5" fill="currentColor"/>
                <circle cx="20" cy="60" r="5" fill="currentColor"/>
                <circle cx="100" cy="60" r="5" fill="currentColor"/>
                <circle cx="60" cy="14" r="3.5" fill="currentColor"/>
                <circle cx="60" cy="66" r="3.5" fill="currentColor"/>
              </svg>
            {:else}
              <!-- Three avatar bubbles, one slightly forward — reads as
                   "a small group, not a stadium." -->
              <svg viewBox="0 0 120 80" width="100%" height="100%">
                <circle cx="38" cy="50" r="14" fill="none"
                  stroke="currentColor" stroke-width="1.4"/>
                <circle cx="38" cy="44" r="5" fill="currentColor"/>
                <path d="M28 60 Q38 52 48 60" fill="none"
                  stroke="currentColor" stroke-width="1.4"/>
                <circle cx="60" cy="38" r="16" fill="none"
                  stroke="currentColor" stroke-width="1.6"/>
                <circle cx="60" cy="31" r="6" fill="currentColor"/>
                <path d="M48 49 Q60 39 72 49" fill="none"
                  stroke="currentColor" stroke-width="1.6"/>
                <circle cx="82" cy="50" r="14" fill="none"
                  stroke="currentColor" stroke-width="1.4"/>
                <circle cx="82" cy="44" r="5" fill="currentColor"/>
                <path d="M72 60 Q82 52 92 60" fill="none"
                  stroke="currentColor" stroke-width="1.4"/>
              </svg>
            {/if}
          </div>
          <h3 class="card-title">{p.title}</h3>
          <p class="card-body">{p.body}</p>
        </li>
      {/each}
    </ul>
  </div>
</div>

<style>
  .page {
    position: relative;
    width: 100%;
    min-height: 100%;
    overflow: hidden;
  }

  /* ── Peripheral orbs ──────────────────────────────────────────
     Pinned to the page corners with absolute positioning so they
     drift behind the content. Pointer-events: none so they never
     intercept clicks. Same shading recipe as EmptyState's
     satellites, blown up + low-opacity. */
  .orbs {
    position: absolute;
    inset: 0;
    pointer-events: none;
    overflow: hidden;
  }
  .orb {
    position: absolute;
    border-radius: 50%;
    opacity: 0.55;
    filter: blur(0.4px);
    background:
      radial-gradient(
        circle at 30% 28%,
        hsl(var(--hue), var(--sat), 78%) 0%,
        hsl(var(--hue), var(--sat), 58%) 32%,
        hsl(var(--hue), var(--sat), 38%) 75%,
        hsl(var(--hue), var(--sat), 24%) 100%
      );
    box-shadow:
      inset -4px -6px 12px hsla(var(--hue), var(--sat), 18%, 0.55),
      inset 4px 4px 8px hsla(var(--hue), var(--sat), 92%, 0.3),
      0 12px 60px hsla(var(--hue), var(--sat), 50%, 0.25);
  }
  /* Top-left, smallest. */
  .orb-a {
    width: 140px;
    height: 140px;
    top: -50px;
    left: -40px;
    animation: drift1 22s ease-in-out infinite alternate;
  }
  /* Right side, mid-height, largest. */
  .orb-b {
    width: 220px;
    height: 220px;
    top: 28%;
    right: -90px;
    animation: drift2 26s ease-in-out infinite alternate;
  }
  /* Bottom-left, medium. */
  .orb-c {
    width: 170px;
    height: 170px;
    bottom: -60px;
    left: 12%;
    animation: drift3 30s ease-in-out infinite alternate;
  }
  /* Top-right, small accent. */
  .orb-d {
    width: 90px;
    height: 90px;
    top: 6%;
    right: 22%;
    opacity: 0.4;
    animation: drift1 18s ease-in-out infinite alternate-reverse;
  }
  @keyframes drift1 {
    from { transform: translate(0, 0) scale(1); }
    to   { transform: translate(20px, 14px) scale(1.06); }
  }
  @keyframes drift2 {
    from { transform: translate(0, 0); }
    to   { transform: translate(-30px, -22px); }
  }
  @keyframes drift3 {
    from { transform: translate(0, 0); }
    to   { transform: translate(24px, -18px); }
  }
  @media (prefers-reduced-motion: reduce) {
    .orb { animation: none; }
  }

  /* ── Content ────────────────────────────────────────────────── */
  .content {
    position: relative;
    z-index: 1;
    max-width: 900px;
    margin: 0 auto;
    padding: 4rem 1.5rem 4rem;
    display: flex;
    flex-direction: column;
    gap: 3.2rem;
  }

  .hero {
    display: flex;
    flex-direction: column;
    align-items: center;
    text-align: center;
    gap: 0.85rem;
  }
  .logo {
    color: var(--color-fg);
    margin-bottom: 0.4rem;
    /* A faint soft glow under the monogram pulls it forward from the
       orbs without using extra chrome. */
    filter: drop-shadow(0 6px 24px color-mix(in srgb, var(--color-fg) 14%, transparent));
  }
  .logo svg { display: block; }

  .kicker {
    margin: 0;
    color: var(--color-fg-muted);
    font-size: 0.86rem;
    letter-spacing: 0.01em;
  }
  .headline {
    margin: 0;
    font-size: clamp(1.6rem, 2.2vw, 2rem);
    line-height: 1.18;
    font-weight: 700;
    letter-spacing: -0.018em;
    max-width: 22ch;
  }
  .lede {
    margin: 0;
    max-width: 50ch;
    color: var(--color-fg-muted);
    font-size: 0.98rem;
    line-height: 1.55;
  }

  .cta-row {
    display: flex;
    gap: 0.6rem;
    margin-top: 0.8rem;
    flex-wrap: wrap;
    justify-content: center;
  }
  .primary,
  .secondary {
    height: 38px;
    padding: 0 18px;
    border-radius: 999px;
    font: inherit;
    font-size: 0.88rem;
    font-weight: 600;
    letter-spacing: -0.005em;
    cursor: pointer;
    transition:
      transform 180ms cubic-bezier(0.22, 1.2, 0.36, 1),
      box-shadow 200ms ease,
      background 160ms ease,
      color 160ms ease;
  }
  .primary {
    background: var(--color-fg);
    color: var(--color-page);
    border: 1px solid var(--color-fg);
  }
  .primary:hover {
    transform: translateY(-1px);
    box-shadow: 0 8px 22px rgba(15, 15, 15, 0.16);
  }
  .secondary {
    background: transparent;
    color: var(--color-fg);
    border: 1px solid var(--color-border);
  }
  .secondary:hover {
    background: var(--color-surface-soft);
  }
  .primary:active,
  .secondary:active { transform: translateY(0); }

  /* ── Value-prop cards ───────────────────────────────────────── */
  .cards {
    list-style: none;
    padding: 0;
    margin: 0;
    display: grid;
    grid-template-columns: repeat(3, minmax(0, 1fr));
    gap: 1rem;
  }
  @media (max-width: 760px) {
    .cards { grid-template-columns: 1fr; }
  }
  .card {
    display: flex;
    flex-direction: column;
    gap: 0.55rem;
    padding: 1.25rem 1.1rem 1.2rem;
    border-radius: 14px;
    background: color-mix(in srgb, var(--color-surface) 92%, transparent);
    border: 1px solid var(--color-border);
    backdrop-filter: blur(8px);
    transition: border-color 160ms ease, transform 240ms ease;
  }
  .card:hover {
    border-color: color-mix(in srgb, var(--color-fg) 22%, var(--color-border));
    transform: translateY(-1px);
  }
  .illus {
    color: var(--color-fg-muted);
    height: 60px;
    display: flex;
    align-items: center;
    justify-content: center;
    margin-bottom: 0.2rem;
  }
  .card-title {
    margin: 0;
    font-size: 0.96rem;
    font-weight: 650;
    letter-spacing: -0.01em;
  }
  .card-body {
    margin: 0;
    color: var(--color-fg-muted);
    font-size: 0.86rem;
    line-height: 1.55;
  }
</style>

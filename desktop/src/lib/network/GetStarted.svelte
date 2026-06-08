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
        <svg viewBox="0 0 634 632" width="62" height="62">
          <path
            fill="currentColor"
            d="M517.107 187.121C520.419 186.936 525.375 187.132 528.815 187.146L547.714 187.14C553.689 187.193 559.871 186.766 565.811 187.189C568.077 187.351 570.622 187.72 572.739 188.563C576.284 189.975 579.85 194.04 581.237 197.461C582.036 199.423 582.222 201.854 582.349 203.955C582.903 213.23 582.503 222.746 582.506 232.041C582.513 240.104 582.992 248.519 582.29 256.548C582.101 258.728 581.698 261.402 580.776 263.393C579.092 267.023 575.587 270.125 571.851 271.426C565.622 273.595 538.12 272.651 529.796 272.635C525.898 272.628 521.19 272.172 517.546 273.717C513.444 275.459 509.538 278.915 507.922 283.131C506.067 287.961 506.606 293.745 506.609 298.832L506.671 326.865C506.686 333.16 507.429 341.996 505.132 347.796C499.535 361.947 484.295 357.078 472.457 357.877C463.319 358.49 452.803 356.336 444.005 359.632C431.99 364.314 433.046 376.134 433.129 386.462L433.201 414.2C433.201 418.291 433.405 425.911 432.981 429.765C432.777 431.714 432.272 433.624 431.492 435.422C427.978 443.395 420.954 444.769 413.072 444.72C398.523 444.636 383.827 444.812 369.302 444.642C362.668 444.565 356.263 439.158 354.489 432.934C353.427 429.198 353.774 422.6 353.78 418.551L353.768 390.538C353.793 385.268 353.907 380.161 353.759 374.837C353.79 366.035 346.292 358.474 337.525 358.029C328.108 357.558 318.691 358.146 309.25 357.827C298.666 357.468 286.398 357.406 281.275 368.7C279.383 372.872 279.917 380.956 279.931 385.593L279.948 412.971C279.949 419.232 280.698 429.681 278.316 435.168C274.268 444.5 265.131 444.927 256.577 444.723C242.493 444.385 228.863 445.082 214.833 444.583C207.943 444.339 202.531 438.74 200.575 432.476C199.474 428.483 199.812 422.649 199.813 418.412L199.854 393.927C199.879 388.001 200.612 374.636 198.975 369.322C194.308 354.172 174.203 358.22 161.818 357.914C150.171 357.623 132.752 362.479 127.734 346.54C125.937 340.83 126.673 330.492 126.667 324.404C126.64 315.803 126.657 307.199 126.718 298.596C126.781 288.941 127.981 279.348 117.553 274.193L117.184 274.015C111.487 272.007 106.525 272.594 100.489 272.632L79.1934 272.67C70.1122 272.676 61.6083 274.101 55.2286 266.509C50.2285 260.559 51.1853 255.205 51.0764 247.967C50.9909 242.298 51.0368 236.718 51.029 231.104L51.0417 213.71C51.0668 206.866 50.3189 200.637 54.2371 194.642C59.4082 186.73 67.6396 187.785 75.9565 187.752L96.7835 187.81C103.937 187.821 111.614 187.489 118.744 187.979C121.36 188.292 123.989 189.231 126.124 190.735C134.236 196.453 133.113 206.751 133.06 215.421L132.926 243.173C132.905 248.525 132.641 254.969 133.403 260.17C133.897 265.327 139.62 271.652 145.003 272.679C154.839 274.33 165.256 273.354 175.332 273.537C187.279 273.755 201.923 270.954 205.953 286.31C207.068 290.557 206.623 296.695 206.612 301.216L206.552 328.351C206.543 332.699 206.332 340.548 206.93 344.661C207.539 349.019 209.869 352.953 213.398 355.583C215.302 356.989 217.742 358.279 220.085 358.573C227.561 359.511 236.427 359.056 244.022 359.115C248.259 359.149 258.843 359.325 262.416 358.728C268.556 357.648 273.615 353.299 275.609 347.394C277.045 343.064 276.542 336.094 276.485 331.331L276.398 304.096C276.404 298.675 276.217 292.831 276.919 287.455C277.804 280.674 283.993 274.298 290.95 273.765C298.969 273.15 307.239 273.616 315.292 273.537C324.25 273.592 333.485 273.149 342.404 273.952C349.189 274.746 354.7 279.509 356.17 286.253C357.266 291.279 356.91 297.104 356.876 302.265L356.765 328.394C356.731 337.577 355.13 349.653 363.529 355.655C370.77 360.829 382.543 358.824 391.13 359.124C398.194 358.793 405.754 359.712 412.75 358.737C428.966 356.481 427 340.359 426.957 329.449L426.904 303.014C426.895 295.859 425.858 285.781 430.452 279.887C432.777 276.94 436.018 274.85 439.661 273.947C444.317 272.751 448.93 273.559 453.673 273.467C464.362 273.258 475.491 274.041 486.106 273.189C491.83 272.729 497.864 268.034 499.563 262.586C500.993 258 500.625 252.065 500.603 247.192L500.576 218.175C500.56 204.088 498.628 189.691 517.107 187.121Z"
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

<script>
  // Reached only by a successfully-signed-in user whose email isn't on the allowlist.
  // No app data is ever loaded here — the gate redirects before any protected route.
</script>

<div class="wall">
  <div class="card">
    <div class="mark" aria-hidden="true">
      <svg viewBox="0 0 113 66" width="40" height="24"><path fill="currentColor" d="M48 0h17v30l1 2c6 2 18-18 25-20 3 1 9 8 11 11-4 6-19 18-21 22v2c2 1 27 1 32 1 0 6 0 11-1 17-12 0-27 1-37-4-8-4-15-12-18-20l-2-8-2 14c-12 21-31 18-52 18 0-6 0-11 0-17 6 0 28 1 31-1l0-1c1-4-17-19-20-24 2-3 8-9 11-11 4-1 18 18 22 20 2 1 2 1 3 0 2-2 1-9 1-12V0Z"/></svg>
    </div>
    <h1>Workbooks Cloud is in private access</h1>
    <p>Your account isn’t on the access list yet. If you think this is a mistake, reach out and we’ll sort it.</p>
    <a class="btn" href="/logout">Sign out</a>
  </div>
</div>

<style>
  .wall { min-height:100dvh; display:grid; place-items:center; padding:24px; background:var(--paper); }
  .card { max-width:440px; text-align:center; background:var(--card); border:2px solid var(--stroke);
    border-radius:14px; box-shadow:3px 3px 0 var(--shadow); padding:40px 32px; }
  .mark { color:var(--ink); display:flex; justify-content:center; margin-bottom:18px; }
  h1 { font-size:21px; margin:0 0 10px; }
  p { color:var(--dim); font-size:14px; line-height:1.6; margin:0 0 22px; }
  .btn { display:inline-block; padding:9px 18px; border:2px solid var(--stroke); border-radius:9px;
    box-shadow:2px 2px 0 var(--shadow); font-weight:600; font-size:13.5px; text-decoration:none; color:inherit; background:var(--card); }
  .btn:hover { background:var(--paper); }
</style>

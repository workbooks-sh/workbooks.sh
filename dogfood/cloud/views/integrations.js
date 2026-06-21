// Integrations — connected services for the nexus (GitHub, model providers, tool brokers, …). A grid of
// service cards with brand logos + a Connect/Connected toggle. v1: connection state is scaffolded
// client-side (wb-connections) — the real per-service OAuth/key flow wires in incrementally on top
// (the native-auth = integrations-OAuth thread). Secrets themselves live in the Admin → Secrets page.

WB.view('/integrations', { title: 'Integrations', accent: 'var(--sky)', async render(el){
  var esc = WB.esc;
  var SERVICES = [
    { id: 'github',    name: 'GitHub',        slug: 'github',        blurb: 'Mirror workspaces to a repo; deploy from git.' },
    { id: 'openrouter',name: 'OpenRouter',    slug: 'openrouter',    blurb: 'One key, every model — routes agent calls.' },
    { id: 'anthropic', name: 'Anthropic',     slug: 'anthropic',     blurb: 'Claude models for your agents.' },
    { id: 'openai',    name: 'OpenAI',        slug: 'openai',        blurb: 'GPT models + embeddings.' },
    { id: 'google',    name: 'Google',        slug: 'google',        blurb: 'Workspace SSO + Gemini.' },
    { id: 'composio',  name: 'Composio',      slug: 'composio',      blurb: 'Hundreds of tool integrations for agents.' },
    { id: 'doppler',   name: 'Doppler',       slug: 'doppler',       blurb: 'Sync secrets from your vault.' },
    { id: 'fal',       name: 'fal',           slug: 'fal',           blurb: 'Fast image / video model inference.' },
    { id: 'slack',     name: 'Slack',         slug: 'slack',         blurb: 'Notify channels from hooks + agents.' },
    { id: 'stripe',    name: 'Stripe',        slug: 'stripe',        blurb: 'Payments + billing for your apps.' }
  ];
  function conns(){ try { return JSON.parse(localStorage.getItem('wb-connections') || '{}'); } catch (e) { return {}; } }
  function setConn(id, on){ var c = conns(); if (on) c[id] = { at: Date.now() }; else delete c[id]; try { localStorage.setItem('wb-connections', JSON.stringify(c)); } catch (e) {} }
  function logo(slug){ return 'https://cdn.simpleicons.org/' + slug; }

  function paint(){
    var c = conns();
    el.innerHTML =
      '<section class="intg">' +
        '<div class="intghd"><h1 class="intgtitle">Integrations</h1>' +
          '<p class="intgsub">Connect services your agents and apps can use. Keys are stored as secrets; OAuth flows land per-service.</p></div>' +
        '<div class="intggrid">' + SERVICES.map(function(s){
          var on = !!c[s.id];
          return '<div class="intgcard' + (on ? ' on' : '') + '">' +
            '<div class="intgtop"><img class="intglogo" src="' + esc(logo(s.slug)) + '" alt="" loading="lazy" onerror="this.style.visibility=\'hidden\'">' +
              '<span class="intgname">' + esc(s.name) + '</span>' + (on ? '<span class="intgdot" title="Connected"></span>' : '') + '</div>' +
            '<p class="intgblurb">' + esc(s.blurb) + '</p>' +
            '<button class="intgbtn' + (on ? ' on' : '') + '" data-conn="' + esc(s.id) + '">' + (on ? 'Connected ✓' : 'Connect') + '</button>' +
          '</div>';
        }).join('') + '</div>' +
      '</section>';
    el.querySelectorAll('[data-conn]').forEach(function(b){
      b.onclick = function(){
        var id = b.getAttribute('data-conn'), on = !!conns()[id];
        setConn(id, !on); WB.toast(on ? 'Disconnected' : (SERVICES.find(function(x){return x.id===id;}).name + ' connected'));
        paint();
      };
    });
  }
  paint();
}});

WB.scopedStyles('/integrations', `
.intg { max-width: 920px; }
.intghd { margin-bottom: 18px; }
.intgtitle { font: 700 26px var(--read); letter-spacing: -0.02em; color: var(--ink); margin: 0; }
.intgsub { font: 500 13px var(--read); color: var(--dim); margin: 4px 0 0; max-width: 560px; }
.intggrid { display: grid; grid-template-columns: repeat(auto-fill, minmax(240px, 1fr)); gap: 12px; }
.intgcard { display: flex; flex-direction: column; gap: 8px; background: var(--card); border: 1px solid var(--line); border-radius: 14px; padding: 16px; transition: border-color .12s; }
.intgcard:hover { border-color: var(--stroke); }
.intgcard.on { border-color: color-mix(in srgb, var(--live) 50%, var(--line)); }
.intgtop { display: flex; align-items: center; gap: 10px; }
.intglogo { width: 22px; height: 22px; object-fit: contain; flex: none; }
.intgname { font: 600 15px var(--read); color: var(--ink); }
.intgdot { margin-left: auto; width: 8px; height: 8px; border-radius: 50%; background: var(--live); flex: none; }
.intgblurb { font: 500 12.5px var(--read); color: var(--dim); line-height: 1.4; flex: 1; }
.intgbtn { border: 1px solid var(--stroke); background: var(--card); color: var(--ink); border-radius: 9px; padding: 8px 0; font: 600 13px var(--read); cursor: pointer; }
.intgbtn:hover { border-color: var(--ink); }
.intgbtn.on { border-color: color-mix(in srgb, var(--live) 50%, var(--line)); color: var(--live); }
`);

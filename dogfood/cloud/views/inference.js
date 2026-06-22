// Admin → AI — Workbooks Inference. Our default LLM provider over the Cloudflare AI Gateway, surfaced as
// "Workbooks Inference" (no provider keys to bring). The org tops off a credit balance, sets a default
// model + spend caps, and sees transparent pricing (5% Cloudflare + 0.5% Workbooks on top-ups). The
// actual gateway routing + Stripe settlement are the runtime/deploy pieces; this is the control surface.

WB.view('/inference', { title: 'AI', accent: 'var(--violet)', async render(el){
  var esc = WB.esc;
  function api(p, opts){ return fetch(p, Object.assign({ credentials:'same-origin', headers:{ 'content-type':'application/json' } }, opts || {})).then(function(r){ return r.json(); }); }
  function money(n){ n = +n || 0; return '$' + n.toFixed(2); }

  el.innerHTML = '<section class="inf"><div class="sechead"><div><h2>AI</h2><p class="dim">Loading…</p></div></div>' +
    '<div class="card faint" style="text-align:center;color:var(--dim)">Loading inference…</div></section>';

  var d = {};
  try { d = await api('/cloud/inference'); } catch (e) {}
  var models = (d && d.models) || [];
  var pricing = (d && d.pricing) || { cloudflare_pct:5.0, workbooks_pct:0.5 };
  var defModel = d.default_model;

  // Model <option>s grouped by provider, each labeled with the provider name.
  function modelOptions(sel){
    var byProv = {};
    models.forEach(function(m){ (byProv[m.provider] = byProv[m.provider] || []).push(m); });
    return Object.keys(byProv).map(function(pv){
      return '<optgroup label="' + esc(WB.providerName(pv)) + '">' +
        byProv[pv].map(function(m){ return '<option value="' + esc(m.id) + '"' + (m.id === sel ? ' selected' : '') + '>' + esc(m.label) + '</option>'; }).join('') +
        '</optgroup>';
    }).join('');
  }
  // A small gallery of the available models, each with its provider chip.
  function modelGallery(){
    return models.map(function(m){
      return '<div class="infm"><span class="infm-ic">' + WB.providerIcon(m.provider) + '</span>' +
        '<div class="infm-tt"><div class="infm-lbl">' + esc(m.label) + '</div>' +
        '<div class="infm-sub">' + esc(WB.providerName(m.provider)) + ' · ' + esc(m.tier || '') + '</div></div></div>';
    }).join('');
  }

  el.innerHTML =
    '<section class="inf">' +
      '<div class="sechead"><div><h2>AI</h2><p>Workbooks Inference — tokens for your agents, no keys to bring.</p></div>' +
        '<button class="btn sm primary" data-topup>Top off credit</button></div>' +

      '<div class="stats">' +
        '<div class="stat"><div class="k">Balance</div><div class="v" id="infBal">' + money(d.balance) + '</div><div class="d dim">Workbooks Inference credit</div></div>' +
        '<div class="stat"><div class="k">Spent this month</div><div class="v">' + money(d.spent_mtd) + '</div><div class="d dim">across all agents</div></div>' +
        '<div class="stat"><div class="k">Provider</div><div class="v" style="font-size:18px">Workbooks</div><div class="d dim">via our infrastructure</div></div>' +
      '</div>' +

      '<div class="card">' +
        '<h3>Default model</h3>' +
        '<p class="note">The model new sessions and agents use unless they pick their own.</p>' +
        '<select class="winput" id="infDefault" style="max-width:340px">' + modelOptions(defModel) + '</select>' +
        '<div class="infgal">' + modelGallery() + '</div>' +
      '</div>' +

      '<div class="card">' +
        '<h3>Spend limits</h3>' +
        '<p class="note">Optional ceilings. Leave blank for no limit.</p>' +
        '<div class="infrow"><label>Monthly cap</label><div class="infin"><span>$</span><input class="winput" id="infMonthly" type="number" min="0" step="1" placeholder="—" value="' + (d.monthly_cap != null ? esc(d.monthly_cap) : '') + '"></div></div>' +
        '<div class="infrow"><label>Per-run cap</label><div class="infin"><span>$</span><input class="winput" id="infRun" type="number" min="0" step="0.1" placeholder="—" value="' + (d.per_run_cap != null ? esc(d.per_run_cap) : '') + '"></div></div>' +
        '<button class="btn sm" data-save>Save settings</button>' +
      '</div>' +

      '<div class="card faint inf-price">' +
        '<h3>Pricing</h3>' +
        '<p class="note">Inference is billed at provider rates with <b>no per-token markup</b>. Top-ups carry two small, transparent fees:</p>' +
        '<div class="infprow"><span>Cloudflare gateway fee</span><span class="mono">' + esc(pricing.cloudflare_pct) + '%</span></div>' +
        '<div class="infprow"><span>Workbooks fee</span><span class="mono">' + esc(pricing.workbooks_pct) + '%</span></div>' +
        '<div class="infprow tot"><span>Total on a top-up</span><span class="mono">' + esc((+pricing.cloudflare_pct + +pricing.workbooks_pct).toFixed(1)) + '%</span></div>' +
        '<p class="inf-foot">Routed through Workbooks’ own infrastructure — the same price as bringing your own keys, with a small Workbooks margin. Prefer to self-serve? You can connect OpenRouter under Toolkits instead.</p>' +
      '</div>' +
    '</section>';

  async function saveConfig(extra){
    var body = Object.assign({
      default_model: el.querySelector('#infDefault').value,
      monthly_cap: el.querySelector('#infMonthly').value || null,
      per_run_cap: el.querySelector('#infRun').value || null
    }, extra || {});
    try { var r = await api('/cloud/inference/config', { method:'POST', body: JSON.stringify(body) }); if (r && r.ok) WB.toast('Settings saved'); else WB.toast((r && r.error) || 'Save failed', 'bad'); }
    catch (e) { WB.toast('Save failed', 'bad'); }
  }

  el.querySelector('[data-save]').onclick = function(){ saveConfig(); };
  el.querySelector('#infDefault').onchange = function(){ saveConfig(); };   // default-model change saves immediately
  el.querySelector('[data-topup]').onclick = async function(){
    var amt = await WB.prompt({ title:'Top off inference credit', placeholder:'Amount in USD, e.g. 25', confirm:'Continue' });
    amt = parseFloat(amt); if (!amt || amt <= 0) return;
    try { var r = await api('/cloud/inference/topup', { method:'POST', body: JSON.stringify({ amount: amt }) });
      WB.toast((r && r.message) || 'Top-up requested'); }
    catch (e) { WB.toast('Could not start top-up', 'bad'); }
  };
}});

WB.scopedStyles('/inference', `
.inf { max-width: 880px; }
.infgal { display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 10px; margin-top: 14px; }
.infm { display: flex; align-items: center; gap: 10px; border: 1px solid var(--line); border-radius: 10px; padding: 10px 12px; }
.infm-ic { display: grid; place-items: center; flex: none; }
.infm-lbl { font: 600 13px var(--read); color: var(--ink); }
.infm-sub { font: 500 11px var(--read); color: var(--dim); text-transform: capitalize; }
.infrow { display: flex; align-items: center; gap: 12px; margin-bottom: 10px; }
.infrow label { width: 110px; font: 600 13px var(--read); color: var(--ink); }
.infin { display: flex; align-items: center; gap: 6px; }
.infin span { color: var(--dim); font: 600 13px var(--mono); }
.infin .winput { width: 140px; }
.inf-price .infprow { display: flex; align-items: center; justify-content: space-between; padding: 6px 0; border-bottom: 1px solid var(--line-soft, var(--line)); font-size: 13px; }
.inf-price .infprow.tot { border-bottom: none; font-weight: 700; }
.inf-foot { margin-top: 12px; font: 500 12px var(--read); color: var(--dim); line-height: 1.5; }
`);

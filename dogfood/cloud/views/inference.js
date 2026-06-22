// Admin → AI — Workbooks Inference. Our default LLM provider over the Cloudflare AI Gateway, surfaced as
// "Workbooks Inference" (no provider keys to bring). One wide page: balance + top-off, a searchable model
// browser (command-palette style) that sets the org default, spend caps, and transparent pricing
// (5% Cloudflare + 0.5% Workbooks on top-ups). Top-ups settle through Polar (card on file reused);
// gateway routing is the remaining runtime piece.

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

  var TIER = {
    frontier:  { label: 'Frontier',  cls: 'frontier' },
    reasoning: { label: 'Reasoning', cls: 'reasoning' },
    fast:      { label: 'Fast',      cls: 'fast' },
    open:      { label: 'Open',      cls: 'open' }
  };
  function tierBadge(t){ var x = TIER[t]; return x ? '<span class="inftier ' + x.cls + '">' + x.label + '</span>' : ''; }

  // One model row in the browser — provider chip, label, id, tier, and a selected check.
  function modelRow(m){
    var on = m.id === defModel;
    return '<button class="infrow2' + (on ? ' on' : '') + '" data-model="' + esc(m.id) + '">' +
      '<span class="infrow2-ic">' + WB.providerIcon(m.provider) + '</span>' +
      '<span class="infrow2-tt"><span class="infrow2-lbl">' + esc(m.label) + '</span>' +
        '<span class="infrow2-id">' + esc(m.id) + '</span></span>' +
      tierBadge(m.tier) +
      '<span class="infrow2-chk">' + (on ? '✓' : '') + '</span></button>';
  }
  // Group rows by provider, with a provider header — the "browse all" experience.
  function modelList(filter){
    var q = (filter || '').trim().toLowerCase();
    var ms = models.filter(function(m){ return !q || (m.label + ' ' + m.id + ' ' + WB.providerName(m.provider)).toLowerCase().indexOf(q) >= 0; });
    if (!ms.length) return '<div class="infempty">No models match “' + esc(filter) + '”.</div>';
    var byProv = {}; ms.forEach(function(m){ (byProv[m.provider] = byProv[m.provider] || []).push(m); });
    return Object.keys(byProv).map(function(pv){
      return '<div class="infgrp"><span class="infgrp-ic">' + WB.providerIcon(pv) + '</span>' + esc(WB.providerName(pv)) +
        '<span class="infgrp-ct">' + byProv[pv].length + '</span></div>' + byProv[pv].map(modelRow).join('');
    }).join('');
  }

  el.innerHTML =
    '<section class="inf">' +
      '<div class="sechead"><div><h2>AI</h2><p>Workbooks Inference — tokens for your agents, no keys to bring.</p></div>' +
        '<button class="btn sm primary" data-topup>Top off credit</button></div>' +

      '<div class="stats">' +
        '<div class="stat"><div class="k">Balance</div><div class="v" id="infBal">' + money(d.balance) + '</div><div class="d dim">Workbooks Inference credit</div></div>' +
        '<div class="stat"><div class="k">Spent this month</div><div class="v">' + money(d.spent_mtd) + '</div><div class="d dim">across all agents</div></div>' +
        '<div class="stat"><div class="k">Default model</div><div class="v" id="infDefLbl" style="font-size:16px">' + esc((models.filter(function(m){return m.id===defModel;})[0]||{}).label || '—') + '</div><div class="d dim">' + esc(models.length) + ' models available</div></div>' +
        '<div class="stat"><div class="k">Provider</div><div class="v" style="font-size:18px">Workbooks</div><div class="d dim">via our infrastructure</div></div>' +
      '</div>' +

      '<div class="infgrid">' +
        // LEFT — the model browser (command-palette style search over every model).
        '<div class="card infmodels">' +
          '<div class="infmhd"><h3>Models</h3><span class="dim" style="font-size:12.5px">Click one to make it your default</span></div>' +
          '<input class="winput infsearch" id="infSearch" placeholder="Search ' + esc(models.length) + ' models — provider, name, or id…" autocomplete="off">' +
          '<div class="infmlist" id="infMList">' + modelList('') + '</div>' +
        '</div>' +
        // RIGHT — limits + pricing.
        '<div class="infside">' +
          '<div class="card">' +
            '<h3>Spend limits</h3><p class="note">Optional ceilings. Blank = no limit.</p>' +
            '<div class="infrow"><label>Monthly</label><div class="infin"><span>$</span><input class="winput" id="infMonthly" type="number" min="0" step="1" placeholder="—" value="' + (d.monthly_cap != null ? esc(d.monthly_cap) : '') + '"></div></div>' +
            '<div class="infrow"><label>Per-run</label><div class="infin"><span>$</span><input class="winput" id="infRun" type="number" min="0" step="0.1" placeholder="—" value="' + (d.per_run_cap != null ? esc(d.per_run_cap) : '') + '"></div></div>' +
            '<button class="btn sm" data-save>Save limits</button>' +
          '</div>' +
          '<div class="card faint inf-price">' +
            '<h3>Pricing</h3>' +
            '<p class="note">Provider rates pass through with <b>no per-token markup</b>. Top-ups carry:</p>' +
            '<div class="infprow"><span>Cloudflare gateway</span><span class="mono">' + esc(pricing.cloudflare_pct) + '%</span></div>' +
            '<div class="infprow"><span>Workbooks</span><span class="mono">' + esc(pricing.workbooks_pct) + '%</span></div>' +
            '<div class="infprow tot"><span>Total on top-ups</span><span class="mono">' + esc((+pricing.cloudflare_pct + +pricing.workbooks_pct).toFixed(1)) + '%</span></div>' +
            '<p class="inf-foot">Routed through Workbooks’ infrastructure — same price as bringing your own keys. Prefer to self-serve? Connect OpenRouter under Toolkits.</p>' +
          '</div>' +
        '</div>' +
      '</div>' +
    '</section>';

  var listEl = el.querySelector('#infMList');
  function repaintList(){ listEl.innerHTML = modelList(el.querySelector('#infSearch').value); wireRows(); }
  function wireRows(){
    listEl.querySelectorAll('[data-model]').forEach(function(b){ b.onclick = function(){ setDefault(b.getAttribute('data-model')); }; });
  }
  async function setDefault(id){
    defModel = id;
    repaintList();
    var m = models.filter(function(x){ return x.id === id; })[0];
    var lbl = el.querySelector('#infDefLbl'); if (lbl && m) lbl.textContent = m.label;
    try { await api('/cloud/inference/config', { method:'POST', body: JSON.stringify({ default_model: id }) }); WB.toast('Default model set to ' + ((m && m.label) || id)); }
    catch (e) { WB.toast('Could not set default', 'bad'); }
  }
  async function saveLimits(){
    var body = { monthly_cap: el.querySelector('#infMonthly').value || null, per_run_cap: el.querySelector('#infRun').value || null };
    try { var r = await api('/cloud/inference/config', { method:'POST', body: JSON.stringify(body) }); if (r && r.ok) WB.toast('Limits saved'); else WB.toast((r && r.error) || 'Save failed', 'bad'); }
    catch (e) { WB.toast('Save failed', 'bad'); }
  }

  el.querySelector('#infSearch').addEventListener('input', repaintList);
  el.querySelector('[data-save]').onclick = saveLimits;
  el.querySelector('[data-topup]').onclick = async function(){
    var amt = await WB.prompt({ title:'Top off inference credit', placeholder:'Amount in USD, e.g. 25', confirm:'Continue' });
    amt = parseFloat(amt); if (!amt || amt <= 0) return;
    try {
      var r = await api('/cloud/inference/topup', { method:'POST', body: JSON.stringify({ amount: amt, success_url: location.origin + location.pathname + '#/inference' }) });
      if (r && r.url) { WB.toast('Redirecting to checkout…'); location.href = r.url; return; }
      if (r && r.error) { WB.toast(r.error, 'bad'); return; }
      WB.toast((r && r.message) || 'Top-up requested');
    }
    catch (e) { WB.toast('Could not start top-up', 'bad'); }
  };
  wireRows();
}});

WB.scopedStyles('/inference', `
.inf { max-width: 1280px; }
.infgrid { display: grid; grid-template-columns: minmax(0, 1.6fr) minmax(280px, 1fr); gap: 16px; align-items: start; }
@media (max-width: 920px) { .infgrid { grid-template-columns: 1fr; } }
.infside { display: flex; flex-direction: column; gap: 16px; }
.infmodels { display: flex; flex-direction: column; min-height: 0; }
.infmhd { display: flex; align-items: baseline; justify-content: space-between; gap: 10px; margin-bottom: 12px; }
.infmhd h3 { margin: 0; }
.infsearch { margin-bottom: 10px; }
.infmlist { max-height: 56vh; overflow-y: auto; margin: 0 -6px; padding: 0 6px; }
.infgrp { display: flex; align-items: center; gap: 8px; font: 700 11px var(--read); letter-spacing: .05em; text-transform: uppercase;
  color: var(--dim); padding: 14px 6px 6px; position: sticky; top: 0; background: var(--card); z-index: 1; }
.infgrp:first-child { padding-top: 2px; }
.infgrp-ic { display: grid; place-items: center; } .infgrp-ic .provglyph, .infgrp-ic .provinit { width: 18px; height: 18px; }
.infgrp-ct { margin-left: auto; font: 600 10.5px var(--mono); background: var(--line); border-radius: 20px; padding: 0 7px; letter-spacing: 0; }
.infrow2 { display: flex; align-items: center; gap: 11px; width: 100%; text-align: left; border: 1px solid transparent;
  background: none; cursor: pointer; border-radius: 9px; padding: 9px 10px; }
.infrow2:hover { background: var(--hover); }
.infrow2.on { border-color: color-mix(in srgb, var(--violet) 60%, var(--line)); background: color-mix(in srgb, var(--violet) 12%, transparent); }
.infrow2-ic { flex: none; display: grid; place-items: center; }
.infrow2-tt { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 1px; }
.infrow2-lbl { font: 600 13.5px var(--read); color: var(--ink); }
.infrow2-id { font: 500 11px var(--mono); color: var(--dim); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.infrow2-chk { flex: none; width: 16px; text-align: center; color: var(--violet); font-weight: 700; }
/* Saturated text on a low-alpha tint of the SAME hue — readable in both light + dark (the prior
   semi-transparent pastel backgrounds washed the text out, esp. Frontier). */
.inftier { flex: none; font: 700 9.5px var(--read); letter-spacing: .04em; text-transform: uppercase; border-radius: 5px; padding: 2px 6px; }
.inftier.frontier { color: #5b9bd5; background: color-mix(in srgb, #5b9bd5 20%, transparent); }
.inftier.reasoning { color: #b48cff; background: color-mix(in srgb, #b48cff 20%, transparent); }
.inftier.fast { color: var(--bloomd); background: color-mix(in srgb, var(--bloom) 18%, transparent); }
.inftier.open { color: #e0b34a; background: color-mix(in srgb, #e0b34a 20%, transparent); }
.infempty { color: var(--dim); padding: 24px 8px; text-align: center; font: 500 13px var(--read); }
.infrow { display: flex; align-items: center; gap: 12px; margin-bottom: 10px; }
.infrow label { width: 64px; font: 600 13px var(--read); color: var(--ink); }
.infin { display: flex; align-items: center; gap: 6px; flex: 1; }
.infin span { color: var(--dim); font: 600 13px var(--mono); }
.infin .winput { flex: 1; }
.inf-price .infprow { display: flex; align-items: center; justify-content: space-between; padding: 6px 0; border-bottom: 1px solid var(--line); font-size: 13px; }
.inf-price .infprow.tot { border-bottom: none; font-weight: 700; }
.inf-foot { margin-top: 12px; font: 500 12px var(--read); color: var(--dim); line-height: 1.5; }
`);

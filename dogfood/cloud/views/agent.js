// Agent editor — launched from the ⋯ on an agent in the Studio composer's agent dropdown. Lets you
// swap the agent's model and tweak its prompt PER ORG (a layered override; the shipped agent block stays
// the default). Saves to /cloud/agent/config. The agent's theme/glyph come from WB.AGENT_THEME.

WB.view('/agent', { title: 'Agent', accent: 'var(--mint)', async render(el){
  var esc = WB.esc;
  function api(p, opts){ return fetch(p, Object.assign({ credentials:'same-origin', headers:{ 'content-type':'application/json' } }, opts || {})).then(function(r){ return r.json(); }); }
  // Name comes from the hash (#/agent/<name>) — prefix-matched routes don't carry path params.
  var name = decodeURIComponent(((location.hash || '').split('/agent/')[1] || '').split('/')[0] || '').trim();

  el.innerHTML = '<section class="age"><div class="card faint" style="text-align:center;color:var(--dim)">Loading agent…</div></section>';
  if (!name){ el.innerHTML = '<section class="age"><div class="card">No agent specified.</div></section>'; return; }

  var d = {};
  try { d = await api('/cloud/agent/config?name=' + encodeURIComponent(name)); } catch (e) {}
  var mr = {};
  try { mr = await api('/cloud/inference'); } catch (e) {}
  var models = (mr && mr.models) || [];

  var th = (WB.AGENT_THEME && WB.AGENT_THEME[name]) || { color:'var(--dim)', bg:'var(--line)', icon:'' };
  var label = d.label || name;
  var curModel = d.model || (mr && mr.default_model) || '';
  var promptVal = d.prompt || '';            // the override (empty = using the shipped default)
  var defPrompt = d.default_prompt || '';

  function modelOptions(sel){
    var byProv = {};
    models.forEach(function(m){ (byProv[m.provider] = byProv[m.provider] || []).push(m); });
    var head = '<option value="">Default (' + esc((mr && mr.default_model) || 'org default') + ')</option>';
    return head + Object.keys(byProv).map(function(pv){
      return '<optgroup label="' + esc(WB.providerName(pv)) + '">' +
        byProv[pv].map(function(m){ return '<option value="' + esc(m.id) + '"' + (m.id === sel ? ' selected' : '') + '>' + esc(m.label) + '</option>'; }).join('') + '</optgroup>';
    }).join('');
  }

  el.innerHTML =
    '<section class="age">' +
      '<button class="agback" data-nav="/studio">← Back to Studio</button>' +
      '<div class="agehd">' +
        '<span class="ageic" style="background:' + th.bg + ';color:' + th.color + '">' + (th.icon || '') + '</span>' +
        '<div><h2 style="margin:0">' + esc(label) + '</h2>' +
          '<div class="agesub">' + (d.toolkit ? 'Provided by the ' + esc(d.toolkit) + ' toolkit' : 'Always-on agent') + '</div></div>' +
      '</div>' +

      '<div class="card">' +
        '<h3>Model</h3>' +
        '<p class="note">Which model this agent runs on. “Default” follows your org’s default model.</p>' +
        '<select class="winput" id="ageModel" style="max-width:340px">' + modelOptions(curModel) + '</select>' +
      '</div>' +

      '<div class="card">' +
        '<h3>Prompt</h3>' +
        '<p class="note">Override the agent’s instructions. Leave blank to use the shipped prompt' + (defPrompt ? ' (shown as the placeholder)' : '') + '.</p>' +
        '<textarea class="winput agept" id="agePrompt" rows="14" placeholder="' + esc(defPrompt || 'The shipped agent prompt is used when this is blank.') + '">' + esc(promptVal) + '</textarea>' +
      '</div>' +

      '<div class="agefoot">' +
        '<button class="btn" data-nav="/studio">Cancel</button>' +
        '<button class="btn primary" data-save>Save changes</button>' +
      '</div>' +
    '</section>';

  el.querySelector('[data-save]').onclick = async function(){
    var body = { name: name, model: el.querySelector('#ageModel').value || null, prompt: el.querySelector('#agePrompt').value };
    try { var r = await api('/cloud/agent/config', { method:'POST', body: JSON.stringify(body) });
      if (r && r.ok){ WB.toast('Saved ' + label); WB.nav('/studio'); } else WB.toast((r && r.error) || 'Save failed', 'bad'); }
    catch (e) { WB.toast('Save failed', 'bad'); }
  };
}});

WB.scopedStyles('/agent', `
.age { max-width: 760px; }
.agback { border: none; background: none; color: var(--dim); cursor: pointer; font: 600 13px var(--read); padding: 4px 0; margin-bottom: 8px; }
.agback:hover { color: var(--ink); }
.agehd { display: flex; align-items: center; gap: 14px; margin-bottom: 18px; }
.ageic { width: 44px; height: 44px; border-radius: 12px; flex: none; display: grid; place-items: center; }
.ageic svg { width: 24px; height: 24px; }
.agesub { font: 600 11px var(--read); text-transform: uppercase; letter-spacing: .05em; color: var(--dim); margin-top: 3px; }
.agept { width: 100%; box-sizing: border-box; font: 500 13px var(--mono); line-height: 1.5; resize: vertical; }
.agefoot { display: flex; justify-content: flex-end; gap: 10px; margin-top: 4px; }
`);

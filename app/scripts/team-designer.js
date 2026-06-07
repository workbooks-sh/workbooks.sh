import { readSave, writeSave } from '../save.js'
import { call } from '../pkg/adbuy_sim.js'

/* ===== two roles, two seats ===== */
const ROLES={
  strategist:{name:"Creative Strategist",icon:"ph-brain",
    info:"Reads the audience and spots the angles and tests worth trying. Higher skill means better instincts; they get sharper over time, so a good strategist's instinct is worth listening to. They propose — you decide."},
  media:{name:"Paid Media Manager",icon:"ph-target",
    info:"Runs the budget across the week — spreading spend evenly, keeping every ad working, and tracking performance so your best ads reach the right people. Keeps every dollar working and waste low."},
};
const SEATS=["strategist","media"];
const FIRST=["Maya","Theo","Priya","Cole","Bex","Diego","Nina","Sam","Ravi","Joss","Lena","Omar","Tess","Kai","Wren","Ada","Marco","Ivy","Sloane","Hugo"];
const LAST=["Park","Vega","Stone","Cruz","Ng","Okafor","Bauer","Reyes","Frost","Lund","Mehta","Dale","Brooks","Sato","Hale","Quinn","Voss","Marsh"];
const SHOTS=["art/headshots/p1.png","art/headshots/p2.png","art/headshots/p3.png","art/headshots/p4.png","art/headshots/p5.png","art/headshots/p6.png"];
const BUDGET_CENTS=80000; // $800 display budget
const TRAIT_LABELS={creative:"creative",analytical:"analytical",fastmover:"fast",meticulous:"meticulous"};

let poolSeed=(Date.now()>>>0);
let shotI=0;
const rnd=a=>a[Math.floor(Math.random()*a.length)];

function simPool(seed,count){
  return JSON.parse(call("team_pool",JSON.stringify({seed,count})));
}

function simToCard(c,i){
  return {
    ...c,
    name:rnd(FIRST)+" "+rnd(LAST),
    shot:SHOTS[(shotI++)%SHOTS.length],
    taken:false,
  };
}

let pool=simPool(poolSeed,8).map((c,i)=>simToCard(c,i));
let hired={strategist:null,media:null}, budget=BUDGET_CENTS;

/* brand lockup from save */
readSave().then(s => {
  if(s&&s.display){document.getElementById('lname').textContent=s.display.name||'Your Studio';
    const lc=document.getElementById('lcrest');lc.style.background=s.display.bg;lc.style.color=s.display.mark;
    lc.innerHTML=`<i class="ph-fill ph-${s.display.glyph}"></i>`;}
});

function dotrow(v,max){let n=Math.round(v/max*10),h='';for(let i=0;i<10;i++)h+=`<b class="${i<n?'on':''}"></b>`;return h;}
function candCard(c,i){
  const seatOpen = !hired[c.role] && budget>=c.cost_cents;
  const traitLabel=TRAIT_LABELS[c.style]||c.style;
  return `<div class="cand ${c.taken?'taken':''}">
    ${c.taken?'<span class="badge">HIRED</span>':''}
    <div class="shot" style="background-image:url('${c.shot}')"></div>
    <div class="nm">${c.name}</div>
    <div class="role">${ROLES[c.role].name}</div>
    <div class="traits"><span class="tr good">${traitLabel}</span></div>
    <div class="attrs">
      <div class="attr"><span class="k">SKILL</span><span class="dots">${dotrow(c.skill_x1000,1000)}</span></div>
      <div class="attr"><span class="k">CERTAINTY</span><span class="dots">${dotrow(c.confidence_bias_x1000,1400)}</span></div>
    </div>
    <div class="cost"><span class="c">$${Math.round(c.cost_cents/100)} to hire</span><span class="s">$${Math.round(c.salary_cents/100)}/wk</span></div>
    <div class="cacts">
      <button class="btn sec shuf" onclick="shuffle(${i})" title="Shuffle"><i class="ph-bold ph-shuffle"></i></button>
      <button class="btn" ${c.taken||!seatOpen?'disabled':''} onclick="doHire(${i})">${c.taken?'Hired':(hired[c.role]?'Seat full':'Hire')}</button>
    </div>
  </div>`;
}
function renderPool(){
  document.getElementById('carousel').innerHTML=pool.map((c,i)=>candCard(c,i)).join('');
  const open=SEATS.filter(s=>!hired[s]).length;
  document.getElementById('poolhint').textContent = open? `${open} seat${open>1?'s':''} to fill — shuffle for someone new` : 'Team assembled — ready to start';
}
function seatCard(role){
  const r=ROLES[role], h=hired[role];
  if(h) return `<div class="seat"><div class="shead"><span class="ric"><i class="ph-fill ${r.icon}"></i></span>
    <span class="rlbl">${r.name}</span><button class="info" onclick="openRole('${role}')">?</button></div>
    <div class="filled"><span class="av" style="background-image:url('${h.shot}')"></span>
      <span class="who"><span class="mn">${h.name}</span><span class="sal">$${Math.round(h.salary_cents/100)}/wk</span></span>
      <button class="fire" onclick="doFire('${role}')" title="Let go">✕</button></div></div>`;
  return `<div class="seat empty"><div class="shead"><span class="ric"><i class="ph-fill ${r.icon}"></i></span>
    <span class="rlbl">${r.name}</span><button class="info" onclick="openRole('${role}')">?</button></div>
    <div class="openhint">empty seat — hire a ${r.name.toLowerCase()}</div></div>`;
}
function renderSeats(){
  document.getElementById('seats').innerHTML=SEATS.map(seatCard).join('');
  document.getElementById('budamt').textContent='$'+Math.round(budget/100);
  document.getElementById('budtot').textContent='of $'+Math.round(BUDGET_CENTS/100);
  document.getElementById('budbar').style.width=(budget/BUDGET_CENTS*100)+'%';
  document.getElementById('next').disabled = !(hired.strategist&&hired.media);
}
function refresh(){renderPool();renderSeats();}

function shuffle(i){
  if(pool[i].taken)return;
  const role=pool[i].role,shot=pool[i].shot;
  const fresh=simPool((poolSeed+i+Date.now())>>>0,1)[0];
  pool[i]={...simToCard(fresh,i),role,shot};
  renderPool();
}
function doHire(i){const c=pool[i];if(c.taken||hired[c.role]||budget<c.cost_cents)return;c.taken=true;budget-=c.cost_cents;hired[c.role]=c;refresh();}
function doFire(role){const h=hired[role];if(!h)return;budget+=h.cost_cents;const p=pool.find(c=>c.id===h.id);if(p)p.taken=false;hired[role]=null;refresh();}
function openRole(role){const r=ROLES[role];document.getElementById('rmname').textContent=r.name;
  document.getElementById('rminfo').textContent=r.info;document.getElementById('rmic').innerHTML=`<i class="ph-fill ${r.icon}"></i>`;
  document.getElementById('rolemodal').classList.add('on');}
function closeRole(ev){if(ev&&ev.target.closest('.rpanel'))return;document.getElementById('rolemodal').classList.remove('on');}
async function next(){
  if(!(hired.strategist&&hired.media))return;
  const s = (await readSave()) || {}
  s.team=SEATS.map(r=>({
    role:ROLES[r].name,
    name:hired[r].name,
    id:hired[r].id,
    style:hired[r].style,
    skill_x1000:hired[r].skill_x1000,
    confidence_bias_x1000:hired[r].confidence_bias_x1000,
    salary_cents:hired[r].salary_cents,
  }));
  await writeSave(s)
  location.href='dashboard.html?resume=1';
}
async function quickHire(){
  for(const role of SEATS){
    if(hired[role]) continue;
    const best = pool.filter(c=>c.role===role&&!c.taken&&budget>=c.cost_cents)
      .sort((a,b)=>b.skill_x1000-a.skill_x1000)[0];
    if(best){ best.taken=true; budget-=best.cost_cents; hired[role]=best; }
  }
  if(hired.strategist&&hired.media) await next();
  else refresh();
}
window.shuffle=shuffle;window.doHire=doHire;window.doFire=doFire;window.next=next;window.openRole=openRole;window.closeRole=closeRole;window.quickHire=quickHire;
refresh();

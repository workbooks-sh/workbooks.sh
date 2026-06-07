// The three ad concepts per wave — card ids map to name + emoji slots.
export const CONCEPTS = [
  // wave 1
  { name:"Problem × Selfie",         cards:"hook_pain,vis_ugc,fmt_video",          slots:["🔥","🤳","🎬"] },
  { name:"Founder × Demo",          cards:"hook_founder,vis_demo,fmt_video",      slots:["🛠️","🔍","🎬"] },
  { name:"FOMO × Cinematic",        cards:"hook_fomo,vis_cine,fmt_video",         slots:["⏳","🎥","🎬"] },
  // wave 2
  { name:"Question × Testimonial",  cards:"hook_question,vis_testimonial,fmt_carousel", slots:["❓","📣","🎠"] },
  { name:"Social Proof × Result",   cards:"hook_social,vis_result,fmt_carousel",  slots:["👥","✨","🎠"] },
  { name:"Stat × Before/After",     cards:"hook_stat,vis_before,fmt_story",       slots:["📊","↔️","📱"] },
  // wave 3
  { name:"FOMO × Flash Deal",       cards:"hook_fomo,vis_cine,off_discount",      slots:["⏳","🎥","⚡"] },
  { name:"Problem × Bundle",         cards:"hook_pain,vis_demo,off_bundle",        slots:["🔥","🔍","📦"] },
  { name:"Question × Free Trial",   cards:"hook_question,vis_ugc,off_trial",      slots:["❓","🤳","🎁"] },
];

// Returns all concept names that use a given card id.
export function conceptsFor(cardId) {
  return CONCEPTS.filter(c => c.cards.split(',').includes(cardId)).map(c => c.name);
}

function wordFreq(text) {
  const freq = new Map();
  for (const w of text.toLowerCase().split(/\s+/).filter(Boolean)) freq.set(w, (freq.get(w)||0)+1);
  return [...freq.entries()].sort((a,b)=>b[1]-a[1]).slice(0,3).map(([w,c])=>w+':'+c).join(' ');
}
console.log(wordFreq('the cat the dog the cat bird cat'));

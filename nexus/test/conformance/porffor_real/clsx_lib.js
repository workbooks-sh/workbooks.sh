function clsx(){let n='';for(let i=0;i<arguments.length;i++){const a=arguments[i];if(!a)continue;
  if(typeof a==='string'||typeof a==='number')n+=(n&&' ')+a;
  else if(typeof a==='object')for(const k in a)if(a[k])n+=(n&&' ')+k;}return n;}
console.log(clsx('a', {b:true, c:false}, 'd', {e:1}));

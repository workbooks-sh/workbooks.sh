;try {
  var ts = (typeof module!=="undefined" && module.exports && module.exports.transpileModule) ? module.exports : globalThis.ts;
  if (!ts || !ts.transpileModule) { Javy.IO.writeSync(2, new TextEncoder().encode("NO ts.transpileModule; keys="+Object.keys(module.exports||{}).slice(0,10).join(","))); throw new Error("no ts"); }
  var buf=new Uint8Array(1<<24), total=0, n;
  while((n=Javy.IO.readSync(0, buf.subarray(total)))>0) total+=n;
  var src=new TextDecoder().decode(buf.subarray(0,total));
  var res=ts.transpileModule(src, {compilerOptions:{target:"es2020", module:"esnext"}});
  Javy.IO.writeSync(1, new TextEncoder().encode(res.outputText));
} catch(e) {
  Javy.IO.writeSync(2, new TextEncoder().encode("\nDRIVER ERR: "+e+"\n"+(e&&e.stack||"")));
}

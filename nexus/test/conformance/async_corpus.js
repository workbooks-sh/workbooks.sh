// G3 async/Promise ordering corpus. Emits a sequence of markers; the INTERLEAVING (microtask vs sync order)
// is what must match node. We collect into an array and print at the end of the first macrotask.
var log = [];
function L(x){ log.push(x); }

L("sync-start");
Promise.resolve().then(function(){ L("p1-then"); }).then(function(){ L("p1-then2"); });
L("sync-mid");
(async function(){
  L("async-enter");
  await 0;
  L("after-await1");
  await Promise.resolve();
  L("after-await2");
})();
L("sync-after-async");
Promise.resolve().then(function(){ L("p2-then"); });
Promise.reject(new Error("e")).catch(function(e){ L("p-catch:" + e.message); }).finally(function(){ L("p-finally"); });
Promise.all([Promise.resolve(1), Promise.resolve(2)]).then(function(a){ L("all:" + a[0] + "," + a[1]); });
Promise.race([Promise.resolve("fast"), Promise.resolve("slow")]).then(function(v){ L("race:" + v); });
Promise.allSettled([Promise.resolve(1), Promise.reject(2)]).then(function(r){ L("settled:" + r[0].status + "," + r[1].status + r[1].reason); });
L("sync-end");

// drain: print after enough microtask turns. Use a chain of thens to defer printing to the very end.
var done = Promise.resolve();
for (var i = 0; i < 20; i++) done = done.then(function(){});
done.then(function(){ console.log(log.join("|")); });

/* Map/Set userland-shim pre-pass for the Porffor lane.
 *
 * Porffor 0.61's native Map iterator is broken: `[...map.entries()]` and `for(const e of
 * map.entries())` throw "undefined is not a function", bare `[...map]` returns garbage, and
 * arrow `map.forEach` only visits the first entry. `map.set/get/has/size/keys()/values()` work.
 * Porffor also cannot compile a computed `[Symbol.iterator]()` method (type error in branch).
 *
 * Fix: replace `new Map(...)`/`new Set(...)` with userland `__PorfMap`/`__PorfSet` classes backed
 * by parallel arrays. Their entries()/keys()/values() return REAL ARRAYS (which Porffor spreads,
 * for-ofs and .maps correctly) instead of lazy iterators, and forEach loops a plain index (no
 * arrow-capture bug). Since the shim has no [Symbol.iterator], bare `for (x of m)` / `[...m]` are
 * rewritten to `m.entries()` (Map) or `m.values()` (Set) for identifiers locally bound to a shim.
 *
 * Limitation: keys are compared with Array.prototype.indexOf (=== / SameValueZero-ish). String,
 * number, boolean keys work exactly like native Map. Object/array keys work by reference identity
 * (indexOf uses ===), which matches native Map reference semantics, but NaN keys are not deduped
 * (indexOf can't find NaN) — a rare edge. Good enough for real-world string/number-keyed Maps.
 *
 * On any parse/transform error the source is returned UNCHANGED (safe fallback).
 */
const acornMod = require('acorn');
const { generate } = require('astring');

function parse(src) {
  for (const sourceType of ['module', 'script']) {
    try { return acornMod.parse(src, { ecmaVersion: 2023, sourceType, allowReturnOutsideFunction: true }); }
    catch (_) {}
  }
  throw new Error('parse failed');
}

const SHIM = `
class __PorfMap {
  constructor(init){
    this.__k=[]; this.__v=[];
    if (init) { for (let __i=0; __i<init.length; __i++) { this.set(init[__i][0], init[__i][1]); } }
  }
  set(key,val){ const i=this.__k.indexOf(key); if(i>=0){this.__v[i]=val;} else {this.__k.push(key); this.__v.push(val);} return this; }
  get(key){ const i=this.__k.indexOf(key); return i>=0 ? this.__v[i] : undefined; }
  has(key){ return this.__k.indexOf(key) >= 0; }
  delete(key){ const i=this.__k.indexOf(key); if(i<0) return false; this.__k.splice(i,1); this.__v.splice(i,1); return true; }
  clear(){ this.__k=[]; this.__v=[]; }
  get size(){ return this.__k.length; }
  keys(){ return this.__k.slice(); }
  values(){ return this.__v.slice(); }
  entries(){ const r=[]; const k=this.__k, v=this.__v; for(let i=0;i<k.length;i++){ r.push([k[i],v[i]]); } return r; }
  forEach(cb,thisArg){ const k=this.__k, v=this.__v; for(let i=0;i<k.length;i++){ cb(v[i], k[i], this); } }
}
class __PorfSet {
  constructor(init){
    this.__a=[];
    if (init) { for (let __i=0; __i<init.length; __i++) { this.add(init[__i]); } }
  }
  add(x){ if(this.__a.indexOf(x)<0){ this.__a.push(x); } return this; }
  has(x){ return this.__a.indexOf(x) >= 0; }
  delete(x){ const i=this.__a.indexOf(x); if(i<0) return false; this.__a.splice(i,1); return true; }
  clear(){ this.__a=[]; }
  get size(){ return this.__a.length; }
  keys(){ return this.__a.slice(); }
  values(){ return this.__a.slice(); }
  entries(){ const r=[]; const a=this.__a; for(let i=0;i<a.length;i++){ r.push([a[i],a[i]]); } return r; }
  forEach(cb,thisArg){ const a=this.__a; for(let i=0;i<a.length;i++){ cb(a[i], a[i], this); } }
}
`;

// Walk every node, invoking visit(node, parent, key).
function walk(node, parent, key, visit) {
  if (!node || typeof node !== 'object') return;
  if (Array.isArray(node)) { for (let i = 0; i < node.length; i++) walk(node[i], parent, key, visit); return; }
  if (typeof node.type !== 'string') return;
  visit(node, parent, key);
  for (const k of Object.keys(node)) {
    if (k === 'type' || k === 'start' || k === 'end' || k === 'loc' || k === 'range') continue;
    walk(node[k], node, k, visit);
  }
}

function transform(src) {
  const ast = parse(src);

  // Pass 1: rewrite `new Map(...)` -> `new __PorfMap(...)`, `new Set(...)` -> `new __PorfSet(...)`.
  // Also collect identifier names bound (const/let/var) directly to such a constructor, per kind,
  // so we can fix bare for-of / spread that need an explicit iterator method.
  const mapVars = new Set();
  const setVars = new Set();
  let touched = false;

  function ctorKind(callee) {
    return callee && callee.type === 'Identifier' && (callee.name === 'Map' || callee.name === 'Set')
      ? callee.name : null;
  }

  walk(ast, null, null, (node) => {
    if (node.type === 'NewExpression') {
      const kind = ctorKind(node.callee);
      if (kind) { node.callee = { type: 'Identifier', name: kind === 'Map' ? '__PorfMap' : '__PorfSet' }; touched = true; }
    }
  });

  // Collect bound identifiers (scan declarators whose init is `new __PorfMap/__PorfSet(...)`).
  walk(ast, null, null, (node) => {
    if (node.type === 'VariableDeclarator' && node.id && node.id.type === 'Identifier' && node.init &&
        node.init.type === 'NewExpression' && node.init.callee && node.init.callee.type === 'Identifier') {
      if (node.init.callee.name === '__PorfMap') mapVars.add(node.id.name);
      else if (node.init.callee.name === '__PorfSet') setVars.add(node.id.name);
    }
  });

  if (!touched) return src; // no Map/Set usage at all

  const isMapId = (n) => n && n.type === 'Identifier' && mapVars.has(n.name);
  const isSetId = (n) => n && n.type === 'Identifier' && setVars.has(n.name);
  // method name for explicit iteration: Map -> entries(), Set -> values()
  const iterMethod = (n) => isMapId(n) ? 'entries' : (isSetId(n) ? 'values' : null);
  const callIter = (n, m) => ({
    type: 'CallExpression', optional: false,
    callee: { type: 'MemberExpression', computed: false, optional: false, object: n,
              property: { type: 'Identifier', name: m } },
    arguments: []
  });

  // Pass 2: bare `for (x of m)` -> `for (x of m.entries()/.values())`, `[...m]` / `f(...m)` -> spread of iter.
  walk(ast, null, null, (node) => {
    if (node.type === 'ForOfStatement') {
      const m = iterMethod(node.right);
      if (m) node.right = callIter(node.right, m);
    } else if (node.type === 'SpreadElement') {
      const m = iterMethod(node.argument);
      if (m) node.argument = callIter(node.argument, m);
    }
  });

  return SHIM + '\n' + generate(ast);
}

function run() {
  const file = process.argv[2];
  const src = require('fs').readFileSync(file, 'utf8');
  let out;
  try { out = transform(src); } catch (_) { out = src; }
  process.stdout.write(out);
}

if (require.main === module) run();
module.exports = { transform };

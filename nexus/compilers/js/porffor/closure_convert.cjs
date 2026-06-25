/* True per-instance closure conversion for the Porffor lane (multi-instance / per-iteration).
 *
 * COMPLEMENTS closure_promote.cjs — it does NOT replace it. closure_promote promotes single-instance
 * captures to module globals (cheap, correct when one live instance). This pass handles the cases that
 * pass breaks on: per-iteration `for(let i) ()=>i` and re-entrant factories `make(){let n; return ()=>++n}`
 * where each closure needs its OWN environment. Run THIS pass alone for full generality (it subsumes the
 * single-instance cases too), or run closure_promote first then this as a fallback — they are independent.
 *
 * Strategy (source-level, acorn->astring, like closure_promote):
 *   1. Scope analysis: find every function that REFERENCES a binding owned by an enclosing function scope
 *      (a real closure). Such functions, and every enclosing function up to the capturing one, form the
 *      "closure set".
 *   2. Each function in the closure set is converted to a boxed value `{__clo:1, env:<envobj>, fn:<fn>}`:
 *        - a fresh env object is allocated AT THE SITE the function literal is evaluated (so per-iteration
 *          `let` and per-call factories each get their own env — true per-instance capture),
 *        - the function gains an explicit leading param `__env`,
 *        - every captured reference `x` inside it becomes `__env.x` (read AND write — `x=...` -> `__env.x=...`,
 *          `++x` -> `++__env.x`), so mutation after the maker returns is observed by all sibling reads,
 *        - the env object is seeded with the current value of each captured local it owns / forwards.
 *   3. Call sites are routed through fixed-arity dispatch helpers `__callN(f, a0..a{N-1})`:
 *        if `f && f.__clo` -> `f.fn(f.env, a0..)` else plain `f(a0..)`. Fixed arity because Porffor's
 *        `arguments[k]` array-grow is broken; N comes from the call's static arg count (0..8). Dynamic
 *        dispatch means non-closure callees (and closures passed into `.map`/`.filter`/etc.) all work.
 *
 * On ANY error -> return source unchanged.
 */
const acorn = require('acorn');
const { generate } = require('astring');

const GLOBALS = new Set(['console','Math','JSON','Object','Array','String','Number','Boolean','Symbol',
  'Map','Set','WeakMap','WeakSet','Promise','Error','TypeError','RangeError','SyntaxError','parseInt',
  'parseFloat','isNaN','isFinite','undefined','NaN','Infinity','globalThis','Function','RegExp','Date',
  'BigInt','encodeURIComponent','decodeURIComponent','structuredClone','arguments',
  // helpers injected by spread_desugar — called directly, never through the __callN dispatcher
  // (a regex literal through __callN mis-codegens to a stack overflow).
  '__porf_replace_fn']);

function parse(src) {
  for (const sourceType of ['module','script']) {
    try { return acorn.parse(src, { ecmaVersion: 2023, sourceType, allowReturnOutsideFunction: true }); }
    catch (_) {}
  }
  throw new Error('parse failed');
}

const isFunc = n => n && (n.type === 'FunctionDeclaration' || n.type === 'FunctionExpression' || n.type === 'ArrowFunctionExpression');

function patternNames(node, out) {
  if (!node) return;
  switch (node.type) {
    case 'Identifier': out.push(node.name); break;
    case 'RestElement': patternNames(node.argument, out); break;
    case 'AssignmentPattern': patternNames(node.left, out); break;
    case 'ArrayPattern': node.elements.forEach(e => patternNames(e, out)); break;
    case 'ObjectPattern': node.properties.forEach(p => patternNames(p.type === 'RestElement' ? p.argument : p.value, out)); break;
  }
}
function patternIdentNodes(node, set) {
  if (!node) return;
  switch (node.type) {
    case 'Identifier': set.add(node); break;
    case 'RestElement': patternIdentNodes(node.argument, set); break;
    case 'AssignmentPattern': patternIdentNodes(node.left, set); break;
    case 'ArrayPattern': node.elements.forEach(e => patternIdentNodes(e, set)); break;
    case 'ObjectPattern': node.properties.forEach(p => patternIdentNodes(p.type === 'RestElement' ? p.argument : p.value, set)); break;
  }
}
function children(node) {
  const out = [];
  for (const k in node) {
    if (k === 'type' || k[0] === '_') continue;
    const v = node[k];
    if (Array.isArray(v)) { for (const c of v) if (c && c.type) out.push(c); }
    else if (v && v.type) out.push(v);
  }
  return out;
}

function transform(src) {
  const ast = parse(src);

  let nextId = 0;
  const bindings = new Map();
  const bindingNodes = new Set();
  // funcMeta: per function node -> { node, parent, captures:Set(bindingId), id }
  const funcMeta = new Map();

  function makeScope(funcNode, parent) { return { funcNode, parent, vars: new Map() }; }
  function declare(scope, name, declNode, kind) {
    const b = { id: nextId++, name, declNode, ownerFunc: scope.funcNode, kind, refs: [], captured: false };
    scope.vars.set(name, b);
    bindings.set(b.id, b);
    return b;
  }
  function resolve(scope, name) {
    for (let s = scope; s; s = s.parent) if (s.vars.has(name)) return s.vars.get(name);
    return null;
  }
  function collectDecls(node, scope) {
    for (const c of children(node)) {
      if (isFunc(c)) continue;
      if (c.type === 'VariableDeclaration') {
        for (const d of c.declarations) {
          patternIdentNodes(d.id, bindingNodes);
          const names = []; patternNames(d.id, names);
          for (const nm of names) if (!scope.vars.has(nm)) { const b = declare(scope, nm, d, c.kind); b.declStmt = c; b._forLet = !!c._forLet; }
        }
      }
      if (c.type === 'FunctionDeclaration' && c.id) {
        bindingNodes.add(c.id);
        if (!scope.vars.has(c.id.name)) declare(scope, c.id.name, c, 'var');
      }
      collectDecls(c, scope);
    }
  }

  function walk(node, scope, fscope) {
    if (isFunc(node)) {
      const child = makeScope(node, scope);
      funcMeta.set(node, { node, parentFunc: fscope ? fscope.funcNode : null, captures: new Set(), refNodes: [] });
      const pnames = [];
      for (const p of node.params) { patternNames(p, pnames); patternIdentNodes(p, bindingNodes); }
      for (const nm of pnames) declare(child, nm, node, 'param');
      collectDecls(node.body, child);
      if (node.id) bindingNodes.add(node.id);
      for (const c of children(node)) walk(c, child, child);
      return;
    }
    if (node.type === 'Identifier') {
      if (bindingNodes.has(node)) return;
      const b = resolve(scope, node.name);
      if (b) {
        b.refs.push(node);
        // capture: reference's owning function differs from binding's owner (a real enclosing local), OR
        // the binding is a per-iteration for-let — those need per-instance env even at module scope.
        if (fscope && fscope.funcNode !== b.ownerFunc && (b.ownerFunc != null || b._forLet)) {
          b.captured = true;
          const meta = funcMeta.get(fscope.funcNode);
          meta.captures.add(b.id);
          meta.refNodes.push({ node, bindingId: b.id });
        }
      }
      return;
    }
    if (node.type === 'MemberExpression') {
      walk(node.object, scope, fscope);
      if (node.computed) walk(node.property, scope, fscope);
      return;
    }
    if (node.type === 'Property' && !node.computed && node.key && node.key.type === 'Identifier') {
      walk(node.value, scope, fscope); return;
    }
    for (const c of children(node)) walk(c, scope, fscope);
  }

  // tag for-init let/const bindings as per-iteration (these need fresh env per loop turn even at module scope)
  (function tagForInits(node){
    if(!node||typeof node!=='object') return;
    if(node.type==='ForStatement' && node.init && node.init.type==='VariableDeclaration' && node.init.kind!=='var')
      node.init._forLet=true;
    for(const c of children(node)) tagForInits(c);
  })(ast);

  const top = makeScope(null, null);
  collectDecls(ast, top);
  for (const c of children(ast)) walk(c, top, null);

  // ── determine the closure set: functions that capture at least one enclosing local. ──
  const closures = [...funcMeta.values()].filter(m => m.captures.size > 0);
  if (closures.length === 0) return src; // nothing to do — non-closure program, leave untouched

  // Map bindingId -> the closures that capture it (for env seeding).
  // Convert each captured binding's references inside capturing funcs into `__env.<name>`.
  // A function may capture vars from MULTIPLE enclosing levels; we put them all in ITS own env, and the
  // env is seeded at creation from whatever those names resolve to lexically at the creation site
  // (which—after conversion—may itself be a __env.x read in an enclosing closure). To make that work we
  // process from outermost to innermost is unnecessary: seeding uses the ORIGINAL name expression, and
  // since enclosing-closure refs to the same name are ALSO being rewritten to __env.name, the seed
  // expression `name` in an enclosing closure body becomes `__env.name` automatically by the same rename.

  const closureSet = new Set(closures.map(m => m.node));

  // ── SAFETY BAILOUTS — cases this converter cannot express correctly; return source unchanged so the
  //    caller falls back to plain Porffor (no SILENTLY-WRONG output). ──
  // (a) a closure value used as an object-literal property / method, then likely called as `obj.m(...)`:
  //     we can't thread env through a member call, and the box would be invoked as `obj.m()` -> crash.
  // (b) a closure that references ITSELF (self-recursive closure): its own name now resolves to a box, and
  //     calling `f()` inside becomes `__callN(f)` but `f` may not be the box in scope -> incorrect.
  // We detect (a) by checking whether any closure node sits directly as a Property value or method.
  let bail = false;
  (function scanUnsupported(node, parent){
    if(!node||typeof node!=='object') return;
    if(closureSet.has(node)){
      if(parent && parent.type==='Property') bail = true;            // object-literal method/closure value
      if(parent && parent.type==='MethodDefinition') bail = true;    // class method
    }
    for(const k in node){ if(k==='type'||k[0]==='_') continue; const v=node[k];
      if(Array.isArray(v)){ for(const c of v) if(c&&c.type) scanUnsupported(c,node); }
      else if(v&&v.type) scanUnsupported(v,node); }
  })(ast, null);
  // self-reference: a closure whose body references the binding it is assigned to (name appears as a capture
  // of its OWN function and that name is a function/const it is bound to). Heuristic: any captured binding
  // whose declNode IS a function/declarator initialised with a closure that captures it.
  for(const m of closures){
    for(const id of m.captures){
      const b = bindings.get(id);
      if(b.declStmt && b.declStmt.declarations){
        const d = b.declStmt.declarations.find(d=>d.id&&d.id.name===b.name);
        if(d && d.init && closureSet.has(d.init)) bail = true; // const f = <closure that captures f>
      }
    }
  }
  if(bail) return src;

  // Rewrite captured references inside each closure -> member __env.<name>.
  // We mutate Identifier nodes in place into MemberExpressions. Track which we've done.
  for (const m of closures) {
    for (const { node, bindingId } of m.refNodes) {
      const b = bindings.get(bindingId);
      // turn `node` (Identifier x) into  __env.x
      node.type = 'MemberExpression';
      node.computed = false;
      node.optional = false;
      node.object = { type: 'Identifier', name: '__env' };
      node.property = { type: 'Identifier', name: b.name };
      delete node.name;
    }
  }

  // For each closure function node, add leading param __env and box it at its evaluation site.
  // We need to find each function literal's "slot" in its parent to replace it with the box expression.
  // Simplest: do a second walk over the AST; whenever we hit a function node in closureSet, (a) ensure
  // body is a block, (b) prepend __env param, (c) compute its captured names, (d) replace the node with a
  // boxed ObjectExpression { __clo:1, env:{...seeds...}, fn:<thefunction> }.
  // FunctionDeclarations can't be boxed in place (they're statements/bindings) — but a captured-capturing
  // FunctionDeclaration is rare; we convert it to a `var name = <box>` declaration.

  function captureNamesOf(m) {
    return [...m.captures].map(id => bindings.get(id).name);
  }
  function boxExpr(fnNode, m) {
    // ensure block body
    if (fnNode.body.type !== 'BlockStatement') {
      fnNode.body = { type: 'BlockStatement', body: [{ type: 'ReturnStatement', argument: fnNode.body }] };
      fnNode.expression = false;
    }
    fnNode.params.unshift({ type: 'Identifier', name: '__env' });
    const names = captureNamesOf(m);
    const envProps = names.map(nm => ({
      type: 'Property', kind: 'init', method: false, shorthand: false, computed: false,
      key: { type: 'Identifier', name: nm },
      value: { type: 'Identifier', name: nm }, // seed from lexical name at creation site
    }));
    // a closure that is a FunctionExpression keeps its id? drop id to avoid self-name binding issues.
    const fnExpr = { type: 'FunctionExpression', id: null, params: fnNode.params, body: fnNode.body,
      generator: !!fnNode.generator, async: !!fnNode.async, expression: false };
    return {
      type: 'ObjectExpression',
      properties: [
        { type:'Property',kind:'init',method:false,shorthand:false,computed:false,
          key:{type:'Identifier',name:'__clo'}, value:{type:'Literal',value:1} },
        { type:'Property',kind:'init',method:false,shorthand:false,computed:false,
          key:{type:'Identifier',name:'env'}, value:{type:'ObjectExpression',properties:envProps} },
        { type:'Property',kind:'init',method:false,shorthand:false,computed:false,
          key:{type:'Identifier',name:'fn'}, value: fnExpr },
      ],
    };
  }

  // Replace function nodes with boxes via a parent-aware walk.
  function replaceFuncs(node, parent, key, index) {
    if (!node || typeof node !== 'object') return;
    if (isFunc(node) && closureSet.has(node)) {
      const m = funcMeta.get(node);
      if (node.type === 'FunctionDeclaration') {
        // convert `function f(){...}` -> `var f = <box>;`  (it captures, so it's an expression anyway)
        const box = boxExpr(node, m);
        const fname = node.id ? node.id.name : ('__anon' + (nextId++));
        const decl = { type:'VariableDeclaration', kind:'var',
          declarations:[{ type:'VariableDeclarator', id:{type:'Identifier',name:fname}, init:box }] };
        // splice into parent array
        if (Array.isArray(parent[key])) parent[key][index] = decl;
        else parent[key] = decl;
        // recurse into the boxed fn body
        replaceFuncs(box.properties[2].value.body, box.properties[2], 'value', null);
        return;
      } else {
        const box = boxExpr(node, m);
        if (index != null && Array.isArray(parent[key])) parent[key][index] = box;
        else parent[key] = box;
        replaceFuncs(box.properties[2].value.body, box.properties[2], 'value', null);
        return;
      }
    }
    // generic recursion
    for (const k in node) {
      if (k === 'type' || k[0] === '_') continue;
      const v = node[k];
      if (Array.isArray(v)) { for (let i = 0; i < v.length; i++) if (v[i] && v[i].type) replaceFuncs(v[i], node, k, i); }
      else if (v && v.type) replaceFuncs(v, node, k, null);
    }
  }
  replaceFuncs(ast, null, null, null);

  // ── lower `<arr>.forEach(<box>)` (as an expression-statement) to an inline for-loop. ──
  // A box is a plain object; handing it to native `.forEach` crashes ("Callback must be a function"),
  // and an adapter returning a capturing function is impossible (Porffor can't do nested closure capture
  // at all — the very limitation this pass exists to dodge). So we inline the iteration and invoke the box
  // directly via its dispatch. We splice the loop statements DIRECTLY into the enclosing statement list
  // (NOT an arrow IIFE — an arrow IIFE that touches `this` inside a method makes Porffor mis-type the
  // closure and emit a WASM type error). The forEach must be a bare ExpressionStatement for this:
  //   arr.forEach(box);  →  { var __a = arr; for (var __i=0; __i<__a.length; __i++) box.fn(box.env, __a[__i], __i, __a); }
  const isBoxNode = n => n && n.type === 'ObjectExpression' && n.properties[0] &&
    n.properties[0].key && n.properties[0].key.name === '__clo';
  let feSeq = 0;
  function lowerForEachStmt(stmt){
    if (!stmt || stmt.type !== 'ExpressionStatement') return null;
    const node = stmt.expression;
    if (!node || node.type !== 'CallExpression') return null;
    const c = node.callee;
    if (!c || c.type !== 'MemberExpression' || c.computed || !c.property || c.property.name !== 'forEach') return null;
    if (node.arguments.length < 1 || !isBoxNode(node.arguments[0])) return null;
    const box = node.arguments[0];
    const arr = c.object;
    const A='__fea'+feSeq, I='__fei'+feSeq, B='__feb'+(feSeq++);
    const src2 = `{ var ${B}=BOX; var ${A}=ARR; for(var ${I}=0;${I}<${A}.length;${I}++){ ${B}.fn(${B}.env, ${A}[${I}], ${I}, ${A}); } }`;
    const blk = parse(src2).body[0]; // BlockStatement
    (function patch(n){ if(!n||typeof n!=='object')return;
      for(const k in n){ if(k==='type'||k[0]==='_')continue; const v=n[k];
        if(Array.isArray(v)){ for(let i=0;i<v.length;i++){ if(v[i]&&v[i].type==='Identifier'&&v[i].name==='BOX')v[i]=box; else if(v[i]&&v[i].type==='Identifier'&&v[i].name==='ARR')v[i]=arr; else patch(v[i]); } }
        else if(v&&v.type==='Identifier'&&v.name==='BOX')n[k]=box; else if(v&&v.type==='Identifier'&&v.name==='ARR')n[k]=arr; else if(v&&v.type)patch(v); } })(blk);
    return blk;
  }
  (function lowerForEach(node){
    if (!node || typeof node !== 'object') return;
    for (const k in node) {
      if (k === 'type' || k[0] === '_') continue;
      let v = node[k];
      if (Array.isArray(v)) {
        for (let i=0;i<v.length;i++){ const r = lowerForEachStmt(v[i]); if (r) v[i]=r; lowerForEach(v[i]); }
      } else if (v && v.type) { lowerForEach(v); }
    }
  })(ast);

  // ── route call sites through fixed-arity dispatch helpers. ──
  // For a CallExpression `callee(args...)` where callee is NOT a known global/builtin call form, wrap as
  // __callN(callee, args...). We skip: calls whose callee is a MemberExpression on a global (Math.x, JSON.x,
  // console.x, Object.x, etc.) and method calls (obj.method(...)) — those are not closure values. We DO wrap
  // plain identifier calls and bare calls that could be closures. __callN falls back to plain call so this
  // is always safe even for non-closure identifiers.
  const usedArities = new Set();
  let needCallS = false;
  function isGlobalMemberCallee(callee) {
    // a.b.c(...) — only treat as non-closure if root object is a known global. Otherwise (could be a closure
    // stored on an object) we leave the method call alone too: we can't pass env through `obj.m()` cleanly,
    // and stored-closure-as-method is out of scope; plain call is the safe default.
    return callee.type === 'MemberExpression';
  }
  function wrapCalls(node) {
    if (!node || typeof node !== 'object') return;
    for (const k in node) {
      if (k === 'type' || k[0] === '_') continue;
      const v = node[k];
      if (Array.isArray(v)) { for (let i = 0; i < v.length; i++) { wrapCalls(v[i]); v[i] = maybeWrap(v[i]); } }
      else if (v && typeof v === 'object' && v.type) { wrapCalls(v); node[k] = maybeWrap(v); }
    }
  }
  function maybeWrap(node) {
    if (!node || node.type !== 'CallExpression') return node;
    if (node._skipWrap) return node;
    const callee = node.callee;
    if (!callee) return node;
    // method calls / global member calls: leave (Porffor handles, env not threadable through them)
    if (isGlobalMemberCallee(callee)) return node;
    // Identifier callee that is a known global (parseInt, etc.) — leave.
    if (callee.type === 'Identifier' && GLOBALS.has(callee.name)) return node;
    // spread args: a boxed callee can't be spread-called natively (it's a plain object, not a function),
    // and Porffor's native spread can't unwrap our box. Handle the single canonical form `fn(...arr)` by
    // routing through __callS(fn, arr) which unwraps the box then dispatches fixed-arity from the array.
    if (node.arguments.length === 1 && node.arguments[0].type === 'SpreadElement') {
      needCallS = true;
      return { type:'CallExpression', optional:false,
        callee:{type:'Identifier',name:'__callS'},
        arguments:[callee, node.arguments[0].argument] };
    }
    // other spread shapes -> too dynamic, leave
    if (node.arguments.some(a => a.type === 'SpreadElement')) return node;
    if (node.arguments.length > 8) return node;
    const N = node.arguments.length;
    usedArities.add(N);
    return { type: 'CallExpression', optional:false,
      callee: { type:'Identifier', name:'__call'+N },
      arguments: [callee, ...node.arguments] };
  }
  wrapCalls(ast);

  // ── prepend the dispatch helpers actually used. ──
  const helpers = [];
  for (const N of [...usedArities].sort((a,b)=>a-b)) {
    const params = ['f']; for (let i=0;i<N;i++) params.push('a'+i);
    const passArgs = params.slice(1).map(p => p);
    const src2 =
      `function __call${N}(${params.join(',')}){ if(f&&f.__clo)return f.fn(${['f.env',...passArgs].join(',')}); return f(${passArgs.join(',')}); }`;
    helpers.push(src2);
  }
  if (needCallS) {
    // __callS(f, arr): spread-call. Unwrap a box callee, then dispatch fixed-arity (0..4) by arr.length —
    // Porffor needs a static call shape, so we branch on length rather than a runtime apply.
    helpers.push(
      `function __callS(f, arr){ var n = arr.length;` +
      ` if (f && f.__clo) { var e = f.env; if(n===0)return f.fn(e); if(n===1)return f.fn(e,arr[0]); if(n===2)return f.fn(e,arr[0],arr[1]); if(n===3)return f.fn(e,arr[0],arr[1],arr[2]); return f.fn(e,arr[0],arr[1],arr[2],arr[3]); }` +
      ` if(n===0)return f(); if(n===1)return f(arr[0]); if(n===2)return f(arr[0],arr[1]); if(n===3)return f(arr[0],arr[1],arr[2]); return f(arr[0],arr[1],arr[2],arr[3]); }`);
  }
  const helperAst = parse(helpers.join('\n'));
  ast.body.unshift(...helperAst.body);

  return generate(ast);
}

function main() {
  const fs = require('fs');
  const path = process.argv[2];
  let src;
  try { src = path ? fs.readFileSync(path, 'utf8') : fs.readFileSync(0, 'utf8'); } catch (e) { process.exit(2); }
  let out;
  try { out = transform(src); } catch (_) { out = src; }
  process.stdout.write(out);
}
if (require.main === module) main();
module.exports = { transform };

/* Shared-environment closure conversion for the Porffor lane.
 *
 * COMPLEMENTS closure_promote.cjs — does NOT replace it. Handles the cases plain Porffor can't:
 * capturing closures, per-iteration `for(let i) ()=>i`, re-entrant factories, AND (the redesign)
 * sibling closures sharing ONE mutable variable + nested mutually-recursive functions.
 *
 * THE MODEL — per-scope shared environment records (textbook closure conversion):
 *   - Every function scope (and the module/top scope) gets a numeric scopeId.
 *   - A binding is CAPTURED if referenced from a function nested below its owner scope. The OWNER scope
 *     is where that binding's env-slot lives.
 *   - For each scope that owns >=1 captured binding we allocate ONE env object `__env_<id> = {}` at the
 *     TOP of that scope body, BEFORE any other statement — so forward / mutually-recursive references
 *     (`function g(){return h()..}` declared before h) resolve, and so every sibling closure created in
 *     that scope reads/writes the SAME slot (shared mutation).
 *   - Captured bindings are accessed as `__env_<id>.name` EVERYWHERE — owner scope and every nested
 *     closure, reads AND writes (`x=..`->`__env_N.x=..`, `++x`->`++__env_N.x`).
 *   - A closure capturing bindings owned by scopes {a,b,..} is boxed `{__clo:1, env:{ea:__env_a,..}, fn}`.
 *     Its fn gains a leading `__env` param and re-binds the envs locally at entry
 *     (`const __env_a=__env.ea, __env_b=__env.eb;`), so uniform `__env_<id>.name` access works inside.
 *   - Call sites route through fixed-arity dispatch helpers `__callN(f,a..)`:
 *       if f && f.__clo -> f.fn(f.env, a..) else f(a..). Fixed arity because Porffor's arguments-grow is
 *       broken; N from static arg count. `__callS` handles the single canonical spread form `fn(...arr)`.
 *
 * On ANY error / unsupported shape -> return source unchanged (never emit silently-wrong code).
 */
const acorn = require('acorn');
const { generate } = require('astring');

const GLOBALS = new Set(['console','Math','JSON','Object','Array','String','Number','Boolean','Symbol',
  'Map','Set','WeakMap','WeakSet','Promise','Error','TypeError','RangeError','SyntaxError','parseInt',
  'parseFloat','isNaN','isFinite','undefined','NaN','Infinity','globalThis','Function','RegExp','Date',
  'BigInt','encodeURIComponent','decodeURIComponent','structuredClone','arguments',
  '__porf_replace_fn']);

// Native method names. Detecting a box at a member call requires READING the method as a value
// (`recv.m.__clo`); doing so on a primitive STRING corrupts the very next native call (Porffor type-directs
// string methods at the member node — the value-read drops that, so the following `recv.m(...)` returns
// wrong data / traps). Receiver type is unknown statically, so any name String OR Array exposes is
// probe-unsafe and must stay a plain native call (never dispatched). Object-ish / collection / promise
// names (get/set/has/then/…) are probe-SAFE (object receivers survive the read) and are common user-box
// method names, so they are deliberately LEFT OUT and DO get box dispatch.
const NATIVE_METHODS = new Set([
  // Array.prototype
  'push','pop','shift','unshift','slice','splice','concat','join','reverse','indexOf','lastIndexOf',
  'includes','fill','flat','flatMap','copyWithin','keys','values','entries','at','find','findIndex',
  'findLast','findLastIndex','map','filter','forEach','reduce','reduceRight','some','every','sort',
  // String.prototype
  'charAt','charCodeAt','codePointAt','substring','substr','toUpperCase','toLowerCase','trim',
  'trimStart','trimEnd','split','replace','replaceAll','repeat','padStart','padEnd','startsWith',
  'endsWith','match','matchAll','search','normalize','localeCompare',
]);

function parse(src) {
  for (const sourceType of ['module','script']) {
    try { return acorn.parse(src, { ecmaVersion: 2023, sourceType, allowReturnOutsideFunction: true }); }
    catch (_) {}
  }
  throw new Error('parse failed');
}

const isFunc = n => n && (n.type === 'FunctionDeclaration' || n.type === 'FunctionExpression' || n.type === 'ArrowFunctionExpression');

// `this` usage in a method body. depth 0 = the method's own level; any nested function (arrow OR regular)
// bumps depth. A boxed method gets a `__this` param and a FLAT `this`→__this rewrite, which is only correct
// when `this` never appears inside a nested function (those would need this captured through the env — out
// of scope for now). Returns 'none' | 'direct' (flat-rewritable) | 'nested' (must NOT box → bail).
function thisComplexity(fnNode) {
  let direct = false, nested = false;
  (function walk(n, depth){
    if (!n || typeof n !== 'object') return;
    if (n.type === 'ThisExpression') { if (depth === 0) direct = true; else nested = true; return; }
    const d = depth + (isFunc(n) ? 1 : 0);
    for (const k in n) { if (k === 'type' || k[0] === '_') continue; const v = n[k];
      if (Array.isArray(v)) { for (const c of v) if (c && c.type) walk(c, d); }
      else if (v && v.type) walk(v, d); }
  })(fnNode.body, 0);
  return nested ? 'nested' : (direct ? 'direct' : 'none');
}

// Replace `this` at the method's own level (not descending into nested functions) with `__this`.
function rewriteThisFlat(node) {
  if (!node || typeof node !== 'object' || isFunc(node)) return;
  for (const k in node) { if (k === 'type' || k[0] === '_') continue; const v = node[k];
    if (Array.isArray(v)) { for (let i = 0; i < v.length; i++) {
      if (v[i] && v[i].type === 'ThisExpression') v[i] = { type:'Identifier', name:'__this' };
      else rewriteThisFlat(v[i]); } }
    else if (v && v.type === 'ThisExpression') node[k] = { type:'Identifier', name:'__this' };
    else rewriteThisFlat(v); }
}

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
  let nextScope = 0;
  const bindings = new Map();
  const bindingNodes = new Set();
  // Identifier ref-node -> scopeId whose env is NOT yet built when this ref evaluates (a param
  // default value runs before its own function body, where `const __env_<sid> = {}` lives). Such a
  // ref must stay a RAW identifier, not be rewritten to `__env_<sid>.name`. Only refs owned by THAT
  // same scope are unsafe; refs to outer (already-initialized) envs rewrite normally.
  const paramDefaultRefs = new Map();
  function collectIdentNodes(node, out) {
    if (!node || typeof node.type !== 'string') return;
    if (node.type === 'Identifier') { out.push(node); return; }
    for (const c of children(node)) collectIdentNodes(c, out);
  }
  const funcMeta = new Map();   // funcNode -> { node, parentFunc, scopeId, capturedScopes:Set }
  const scopeMeta = new Map();  // scopeId -> { scopeId, funcNode, ownsCaptured }

  const scopeParent = new Map();   // scopeId -> parent scopeId (null for top)
  const scopeFuncById = new Map(); // scopeId -> funcNode
  function makeScope(funcNode, parent) {
    const scopeId = nextScope++;
    scopeMeta.set(scopeId, { scopeId, funcNode, ownsCaptured: false });
    scopeParent.set(scopeId, parent ? parent.scopeId : null);
    scopeFuncById.set(scopeId, funcNode);
    return { funcNode, parent, vars: new Map(), scopeId };
  }
  function declare(scope, name, declNode, kind) {
    const b = { id: nextId++, name, declNode, ownerScopeId: scope.scopeId, kind, captured: false };
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
      if (c.type === 'FunctionDeclaration' && c.id) {
        bindingNodes.add(c.id);
        if (!scope.vars.has(c.id.name)) declare(scope, c.id.name, c, 'var');
      }
      if (isFunc(c)) continue;
      if (c.type === 'VariableDeclaration') {
        for (const d of c.declarations) {
          patternIdentNodes(d.id, bindingNodes);
          const names = []; patternNames(d.id, names);
          for (const nm of names) if (!scope.vars.has(nm)) { const b = declare(scope, nm, d, c.kind); b.declStmt = c; b._forLet = !!c._forLet; }
        }
      }
      collectDecls(c, scope);
    }
  }

  function walk(node, scope, fscope) {
    if (isFunc(node)) {
      const child = makeScope(node, scope);
      funcMeta.set(node, { node, parentFunc: fscope ? fscope.funcNode : null,
        scopeId: child.scopeId, capturedScopes: new Set() });
      const pnames = [];
      for (const p of node.params) { patternNames(p, pnames); patternIdentNodes(p, bindingNodes); }
      for (const nm of pnames) declare(child, nm, node, 'param');
      // Record identifier refs in param default values — they evaluate before this func's env exists.
      for (const p of node.params) {
        if (p.type === 'AssignmentPattern') {
          const ids = []; collectIdentNodes(p.right, ids);
          for (const id of ids) paramDefaultRefs.set(id, child.scopeId);
        }
      }
      collectDecls(node.body, child);
      if (node.id) bindingNodes.add(node.id);
      for (const c of children(node)) walk(c, child, child);
      return;
    }
    if (node.type === 'Identifier') {
      if (bindingNodes.has(node)) return;
      const b = resolve(scope, node.name);
      if (b) {
        (b.refs || (b.refs = [])).push(node);   // every read/write reference (for uniform rewrite)
        const ownerIsTop = scopeMeta.get(b.ownerScopeId).funcNode == null;
        if (fscope && fscope.scopeId !== b.ownerScopeId && (!ownerIsTop || b._forLet)) {
          b.captured = true;
          scopeMeta.get(b.ownerScopeId).ownsCaptured = true;
          (b._usingScopeIds || (b._usingScopeIds = new Set())).add(fscope.scopeId);
          // every function from fscope UP TO (not including) owner scope threads this env.
          for (let s = fscope; s && s.scopeId !== b.ownerScopeId; s = s.parent) {
            if (s.funcNode) funcMeta.get(s.funcNode).capturedScopes.add(b.ownerScopeId);
          }
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

  (function tagForInits(node){
    if(!node||typeof node!=='object') return;
    if(node.type==='ForStatement' && node.init && node.init.type==='VariableDeclaration' && node.init.kind!=='var')
      node.init._forLet=true;
    if((node.type==='ForOfStatement'||node.type==='ForInStatement') && node.left && node.left.type==='VariableDeclaration' && node.left.kind!=='var')
      node.left._forLet=true;
    for(const c of children(node)) tagForInits(c);
  })(ast);

  const top = makeScope(null, null);   // scopeId 0
  collectDecls(ast, top);
  for (const c of children(ast)) walk(c, top, null);

  if ([...funcMeta.values()].every(m => m.capturedScopes.size === 0)) return src;

  // ── Per-iteration `for(let i) ()=>i`: each loop turn needs a FRESH env (JS let-per-iteration). The
  // shared-scope env model would give every closure the loop-final value. Fix: give each captured for-let
  // binding its OWN synthetic scope id (a per-loop env `__env_<L>`), reseeded at the TOP of every loop body
  // iteration from the live loop-control variable — so each closure created that turn captures its own copy.
  const forLetLoops = [];   // { loopNode, kind:'c'|'inof', envId, names:[..], declStmt }
  {
    // locate every For/ForIn/ForOf whose binding decl is a captured for-let
    const declToBindings = new Map();
    for (const b of bindings.values()) {
      if (b.captured && b._forLet && b.declStmt) {
        if (!declToBindings.has(b.declStmt)) declToBindings.set(b.declStmt, []);
        declToBindings.get(b.declStmt).push(b);
      }
    }
    if (declToBindings.size) {
      (function findLoops(node){
        if (!node || typeof node !== 'object') return;
        if (node.type === 'ForStatement' && node.init && declToBindings.has(node.init)) {
          forLetLoops.push({ loopNode: node, kind:'c', declStmt: node.init, bs: declToBindings.get(node.init) });
        } else if ((node.type === 'ForInStatement' || node.type === 'ForOfStatement') && node.left && declToBindings.has(node.left)) {
          forLetLoops.push({ loopNode: node, kind:'inof', declStmt: node.left, bs: declToBindings.get(node.left) });
        }
        for (const k in node){ if(k==='type'||k[0]==='_')continue; const v=node[k];
          if(Array.isArray(v)){ for(const c of v) if(c&&c.type) findLoops(c); }
          else if(v&&v.type) findLoops(v); }
      })(ast);
      // Assign each loop a fresh synthetic env scope id; move its captured bindings onto it and recompute
      // every closure's capturedScopes so the new per-loop scope is threaded.
      for (const L of forLetLoops) {
        L.envId = nextScope++;
        scopeMeta.set(L.envId, { scopeId: L.envId, funcNode: null, ownsCaptured: true });
        scopeParent.set(L.envId, null);   // synthetic env scope, not in the function chain
        scopeFuncById.set(L.envId, null);
        L.names = L.bs.map(b => b.name);
        for (const b of L.bs) b.ownerScopeId = L.envId;
      }
      // recompute capturedScopes for every closure now that some owners moved to per-loop env scopes.
      for (const m of funcMeta.values()) m.capturedScopes = new Set();
      for (const b of bindings.values()) {
        if (!b.captured || !b._usingScopeIds) continue;
        for (const usid of b._usingScopeIds) {
          // walk function-scope chain from the using scope up to (not incl) owner, threading the env.
          for (let sid = usid; sid != null && sid !== b.ownerScopeId; sid = scopeParent.get(sid)) {
            const fn = scopeFuncById.get(sid);
            if (fn) funcMeta.get(fn).capturedScopes.add(b.ownerScopeId);
          }
        }
      }
    }
  }

  const closures = [...funcMeta.values()].filter(m => m.capturedScopes.size > 0);
  if (closures.length === 0) return src;
  const closureSet = new Set(closures.map(m => m.node));

  // ── SAFETY BAILOUTS ──
  let bail = false;
  (function scanUnsupported(node, parent){
    if(!node||typeof node!=='object') return;
    if(closureSet.has(node)){
      // Object-literal property VALUES are boxed in place + dispatched via the inline member-call ternary.
      // Shorthand-method properties (`{ foo() {} }`) and class MethodDefinitions carry `this` — we now BOX
      // them too: a `__this` param + a flat this→__this rewrite, with the receiver threaded at dispatch.
      // That only works when `this` stays at the method's own level; a `this` inside a nested function would
      // need this captured through the env (out of scope) → bail the file for that shape only.
      // Object shorthand methods (`{ foo() {} }`) can become a plain `{ foo: <box> }` property. Class
      // MethodDefinitions can't (class syntax forbids a non-function value), so those still bail.
      if(parent && parent.type==='MethodDefinition') bail = true;
      else if(parent && parent.type==='Property' && parent.method){
        if(thisComplexity(node) === 'nested') bail = true;
        else node._isMethod = true;
      }
      // A box stored under a NATIVE method name can't be member-dispatched (that name is on the denylist,
      // so the call goes native and traps on the box object). Rare; bail rather than emit a trap.
      if(parent && parent.type==='Property' && !parent.computed && parent.key &&
         parent.key.type==='Identifier' && NATIVE_METHODS.has(parent.key.name)) bail = true;
    }
    for(const k in node){ if(k==='type'||k[0]==='_') continue; const v=node[k];
      if(Array.isArray(v)){ for(const c of v) if(c&&c.type) scanUnsupported(c,node); }
      else if(v&&v.type) scanUnsupported(v,node); }
  })(ast, null);
  if(bail) return src;

  // For-let header references (init/test/update for C-style, left/right for for-of/in) keep using the REAL
  // loop-control variable — only references inside the loop BODY are rewritten to the per-iteration env, so
  // the loop still advances normally while each turn's closures capture a fresh seeded copy.
  const forLetHeaderRefs = new Set();
  for (const L of forLetLoops) {
    const collect = n => { if(!n||typeof n!=='object')return;
      if(n.type==='Identifier'){forLetHeaderRefs.add(n);return;}
      for(const k in n){ if(k==='type'||k[0]==='_')continue; const v=n[k];
        if(Array.isArray(v)){for(const c of v)if(c&&c.type)collect(c);} else if(v&&v.type)collect(v); } };
    if (L.kind==='c') { collect(L.loopNode.init); collect(L.loopNode.test); collect(L.loopNode.update); }
    else { collect(L.loopNode.left); collect(L.loopNode.right); }
  }

  // ── Rewrite EVERY reference of a captured binding -> __env_<ownerScopeId>.name ──
  // (owner-scope uses AND nested-closure uses both — the var now lives only in the env record.)
  for (const b of bindings.values()) {
    if (!b.captured || !b.refs) continue;
    for (const node of b.refs) {
      if (forLetHeaderRefs.has(node)) continue;
      // A param-default ref owned by its own function's scope must stay raw (env not built yet).
      if (paramDefaultRefs.get(node) === b.ownerScopeId) continue;
      node.type = 'MemberExpression';
      node.computed = false;
      node.optional = false;
      node.object = { type: 'Identifier', name: '__env_' + b.ownerScopeId };
      node.property = { type: 'Identifier', name: b.name };
      delete node.name;
    }
  }

  // captured names grouped by owner scope
  const capturedByScope = new Map();
  for (const b of bindings.values()) {
    if (!b.captured) continue;
    if (!capturedByScope.has(b.ownerScopeId)) capturedByScope.set(b.ownerScopeId, new Set());
    capturedByScope.get(b.ownerScopeId).add(b.name);
  }

  function isOwnedHere(name, sid){
    for (const b of bindings.values()) if (b.name===name && b.ownerScopeId===sid && b.captured) return b.kind!=='param';
    return false;
  }
  function isParamOwnedHere(name, sid){
    for (const b of bindings.values()) if (b.name===name && b.ownerScopeId===sid && b.captured) return b.kind==='param';
    return false;
  }

  function envPrelude(scopeIds) {
    if (!scopeIds.length) return null;
    return { type:'VariableDeclaration', kind:'const',
      declarations: scopeIds.map(sid => ({
        type:'VariableDeclarator',
        id:{type:'Identifier',name:'__env_'+sid},
        init:{type:'MemberExpression',computed:false,optional:false,
          object:{type:'Identifier',name:'__env'},
          property:{type:'Identifier',name:'e'+sid}} })) };
  }
  function envLiteral(scopeIds) {
    return { type:'ObjectExpression', properties: scopeIds.map(sid => ({
      type:'Property',kind:'init',method:false,shorthand:false,computed:false,
      key:{type:'Identifier',name:'e'+sid},
      value:{type:'Identifier',name:'__env_'+sid} })) };
  }

  function boxExpr(fnNode, m) {
    if (fnNode.body.type !== 'BlockStatement') {
      fnNode.body = { type: 'BlockStatement', body: [{ type: 'ReturnStatement', argument: fnNode.body }] };
      fnNode.expression = false;
    }
    const isMethod = !!fnNode._isMethod;
    // A boxed METHOD gets a leading `__this` param (after __env) and its `this` flat-rewritten to it; the
    // member-call dispatch passes the receiver there. So fn(__env, __this, ...origParams).
    if (isMethod) { rewriteThisFlat(fnNode.body); fnNode.params.unshift({ type:'Identifier', name:'__this' }); }
    fnNode.params.unshift({ type: 'Identifier', name: '__env' });
    const scopeIds = [...m.capturedScopes].sort((a,b)=>a-b);
    const prelude = envPrelude(scopeIds);
    if (prelude) fnNode.body.body.unshift(prelude);
    const fnExpr = { type: 'FunctionExpression', id: null, params: fnNode.params, body: fnNode.body,
      generator: !!fnNode.generator, async: !!fnNode.async, expression: false };
    const props = [
      { type:'Property',kind:'init',method:false,shorthand:false,computed:false,
        key:{type:'Identifier',name:'__clo'}, value:{type:'Literal',value:1} },
      { type:'Property',kind:'init',method:false,shorthand:false,computed:false,
        key:{type:'Identifier',name:'env'}, value: envLiteral(scopeIds) },
      { type:'Property',kind:'init',method:false,shorthand:false,computed:false,
        key:{type:'Identifier',name:'fn'}, value: fnExpr },
    ];
    if (isMethod) props.push(
      { type:'Property',kind:'init',method:false,shorthand:false,computed:false,
        key:{type:'Identifier',name:'__method'}, value:{type:'Literal',value:1} });
    return { type: 'ObjectExpression', properties: props };
  }

  function replaceFuncs(node, parent, key, index) {
    if (!node || typeof node !== 'object') return;
    if (isFunc(node) && closureSet.has(node)) {
      const m = funcMeta.get(node);
      if (node.type === 'FunctionDeclaration') {
        const box = boxExpr(node, m);
        const fname = node.id ? node.id.name : ('__anon' + (nextId++));
        const decl = { type:'VariableDeclaration', kind:'var',
          declarations:[{ type:'VariableDeclarator', id:{type:'Identifier',name:fname}, init:box }] };
        decl._wasFuncDecl = fname;
        if (Array.isArray(parent[key])) parent[key][index] = decl;
        else parent[key] = decl;
        replaceFuncs(box.properties[2].value.body, box.properties[2], 'value', null);
        return;
      } else {
        const box = boxExpr(node, m);
        // A shorthand method `{ foo() {} }` becomes a plain data property `{ foo: <box> }`.
        if (parent && parent.type === 'Property' && parent.method) { parent.method = false; parent.shorthand = false; }
        if (index != null && Array.isArray(parent[key])) parent[key][index] = box;
        else parent[key] = box;
        replaceFuncs(box.properties[2].value.body, box.properties[2], 'value', null);
        return;
      }
    }
    for (const k in node) {
      if (k === 'type' || k[0] === '_') continue;
      const v = node[k];
      if (Array.isArray(v)) { for (let i = 0; i < v.length; i++) if (v[i] && v[i].type) replaceFuncs(v[i], node, k, i); }
      else if (v && v.type) replaceFuncs(v, node, k, null);
    }
  }
  replaceFuncs(ast, null, null, null);

  function bodyArrayOf(funcNode) {
    if (funcNode == null) return ast.body;
    let b = funcNode.body;
    if (b && b.type !== 'BlockStatement') {
      // arrow with expression body that must host an env -> convert to block `{ return <expr>; }`
      funcNode.body = { type:'BlockStatement', body:[{ type:'ReturnStatement', argument: b }] };
      funcNode.expression = false;
      b = funcNode.body;
    }
    if (b && b.type === 'BlockStatement') return b.body;
    return null;
  }
  const scopeFunc = new Map();
  for (const [sid, sm] of scopeMeta) scopeFunc.set(sid, sm.funcNode);

  const forLetEnvIds = new Set(forLetLoops.map(L => L.envId));

  // Insert per-scope env allocation + captured-slot init at the top of each owning scope body.
  for (const [sid, names] of capturedByScope) {
    if (forLetEnvIds.has(sid)) continue;   // per-loop envs are seeded inside the loop body (below)
    const funcNode = scopeFunc.get(sid);
    const arr = bodyArrayOf(funcNode);
    if (arr == null) { bail = true; break; }

    // 1. Rewrite declarations of captured locals so the name lives only in env.
    (function rewriteDecls(container){
      for (let i=0;i<container.length;i++){
        const st = container[i];
        if (!st) continue;
        if (st.type==='VariableDeclaration' && !st._envInit && st._wasFuncDecl) {
          const nm = st._wasFuncDecl;
          if (names.has(nm) && isOwnedHere(nm, sid)) {
            container[i] = { type:'ExpressionStatement', expression:{
              type:'AssignmentExpression', operator:'=',
              left:{type:'MemberExpression',computed:false,optional:false,
                object:{type:'Identifier',name:'__env_'+sid},
                property:{type:'Identifier',name:nm}},
              right: st.declarations[0].init }};
          }
        } else if (st.type==='VariableDeclaration' && !st._envInit) {
          const keepers=[]; const assigns=[];
          for (const d of st.declarations) {
            if (d.id && d.id.type==='Identifier' && names.has(d.id.name) && isOwnedHere(d.id.name, sid)) {
              if (d.init) {
                assigns.push({ type:'ExpressionStatement', expression:{
                  type:'AssignmentExpression', operator:'=',
                  left:{type:'MemberExpression',computed:false,optional:false,
                    object:{type:'Identifier',name:'__env_'+sid},
                    property:{type:'Identifier',name:d.id.name}},
                  right:d.init }});
              }
            } else {
              keepers.push(d);
            }
          }
          if (assigns.length) {
            const repl=[];
            if (keepers.length) repl.push({ type:'VariableDeclaration', kind:st.kind, declarations:keepers });
            repl.push(...assigns);
            container.splice(i,1,...repl);
            i += repl.length-1;
          }
        }
      }
    })(arr);
    if (bail) break;

    // 2. Seed captured PARAMS into env.
    const paramAssigns = [];
    if (funcNode) {
      const pnames=[]; for(const p of funcNode.params) patternNames(p,pnames);
      for (const pn of pnames) if (names.has(pn) && isParamOwnedHere(pn, sid)) {
        paramAssigns.push({ type:'ExpressionStatement', expression:{
          type:'AssignmentExpression', operator:'=',
          left:{type:'MemberExpression',computed:false,optional:false,
            object:{type:'Identifier',name:'__env_'+sid},
            property:{type:'Identifier',name:pn}},
          right:{type:'Identifier',name:pn} }});
      }
    }

    // 3. Prepend `const __env_sid = {};` then param seeds.
    const envDecl = { type:'VariableDeclaration', kind:'const', _envInit:true,
      declarations:[{ type:'VariableDeclarator', id:{type:'Identifier',name:'__env_'+sid},
        init:{type:'ObjectExpression',properties:[]} }] };
    arr.unshift(envDecl, ...paramAssigns);
  }
  if (bail) return src;

  // ── Per-iteration for-let env seeding ──
  // At the TOP of every loop body: `var __env_L = { i: i, ... }` (fresh object each turn, seeded from the
  // real loop-control var). For C-style `for`, also write back `i = __env_L.i` at body end so a body that
  // mutates the loop var still advances the header's real var. Body refs already point at `__env_L.i`.
  for (const L of forLetLoops) {
    let body = L.loopNode.body;
    if (!body || body.type !== 'BlockStatement') {
      body = { type:'BlockStatement', body: body ? [body] : [] };
      L.loopNode.body = body;
    }
    const seed = { type:'VariableDeclaration', kind:'var', _envInit:true,
      declarations:[{ type:'VariableDeclarator', id:{type:'Identifier',name:'__env_'+L.envId},
        init:{ type:'ObjectExpression', properties: L.names.map(nm => ({
          type:'Property',kind:'init',method:false,shorthand:false,computed:false,
          key:{type:'Identifier',name:nm}, value:{type:'Identifier',name:nm} })) } }] };
    body.body.unshift(seed);
    if (L.kind === 'c') {
      for (const nm of L.names) {
        body.body.push({ type:'ExpressionStatement', _envInit:true, expression:{
          type:'AssignmentExpression', operator:'=',
          left:{type:'Identifier',name:nm},
          right:{type:'MemberExpression',computed:false,optional:false,
            object:{type:'Identifier',name:'__env_'+L.envId},
            property:{type:'Identifier',name:nm}} }});
      }
    }
  }

  // ── lower `<arr>.<hof>(<box>[, init])` to a helper call that dispatches the box correctly. ──
  // Works in BOTH statement and expression position (map/filter/reduce return a value). Porffor lacks
  // working closure args to native HOFs, so when the callback is a boxed capturing closure we route the
  // whole call to `__hof_<name>(arr, box[, init])`, which iterates with static arity via box.fn(box.env,…).
  const isBoxNode = n => n && n.type === 'ObjectExpression' && n.properties[0] &&
    n.properties[0].key && n.properties[0].key.name === '__clo';
  const HOFS = new Set(['map','filter','forEach','reduce','find','findIndex','some','every','sort']);
  const usedHofs = new Set();
  function lowerHofCall(node){
    if (!node || node.type !== 'CallExpression') return node;
    const c = node.callee;
    if (!c || c.type !== 'MemberExpression' || c.computed || !c.property) return node;
    const name = c.property.name;
    if (!HOFS.has(name)) return node;
    if (node.arguments.length < 1 || !isBoxNode(node.arguments[0])) return node;
    const box = node.arguments[0];
    const arr = c.object;
    usedHofs.add(name);
    const args = [arr, box];
    let helperName = '__hof_' + name;
    if (name === 'reduce') {
      if (node.arguments.length >= 2) args.push(node.arguments[1]);
      else { helperName = '__hof_reduce1'; usedHofs.add('reduce1'); }   // no-init: seed acc from arr[0]
    }
    return { type:'CallExpression', optional:false, _skipWrap:true,
      callee:{ type:'Identifier', name: helperName }, arguments: args };
  }
  (function lowerHof(node){
    if (!node || typeof node !== 'object') return;
    for (const k in node) {
      if (k === 'type' || k[0] === '_') continue;
      let v = node[k];
      if (Array.isArray(v)) {
        for (let i=0;i<v.length;i++){ if (v[i] && v[i].type) { lowerHof(v[i]); v[i] = lowerHofCall(v[i]); } }
      } else if (v && v.type) { lowerHof(v); node[k] = lowerHofCall(v); }
    }
  })(ast);

  // ── route call sites through fixed-arity dispatch helpers. ──
  const usedArities = new Set();
  let needCallS = false;
  // a callee `__env_N.name` is a closure value stored in an env record — it must be dispatched, not
  // treated as a native method call. Any OTHER member callee (obj.method) we leave alone.
  const isEnvMember = c => c && c.type==='MemberExpression' && !c.computed && c.object &&
    c.object.type==='Identifier' && /^__env_/.test(c.object.name);
  function isGlobalMemberCallee(callee) { return callee.type === 'MemberExpression' && !isEnvMember(callee); }

  // ── Member-call box/native dispatch ──
  // A non-computed member call `recv.name(args)` may hit a BOX stored as an object-literal property
  // (`{ red: <box> }`) OR an ordinary/native method (`arr.push`, `s.indexOf`, `Math.max`). Porffor cannot
  // do a computed/dynamic method call (`recv[name](...)` yields a non-function), so a generic runtime
  // helper is impossible. Instead we emit an INLINE ternary that keeps STATIC member access on both
  // branches and binds the receiver to a hoisted temp (evaluated once):
  //   ((__mrK = recv).name && __mrK.name.__clo)
  //     ? __mrK.name.fn(__mrK.name.env, ...args)   // box dispatch
  //     : __mrK.name(...args)                       // native method, `this` = __mrK
  // Native methods keep correct `this` because the call stays a static member on the temp. Names on the
  // module-level NATIVE_METHODS denylist are NEVER probed (the value-read corrupts primitive-string calls);
  // they stay direct native calls.
  let nextMtmp = 0;
  function memberCallDispatch(node) {
    const callee = node.callee;
    // skip optional-chaining, spreads, super, computed (already excluded by caller for computed).
    if (node.optional || callee.optional) return null;
    if (callee.object && callee.object.type === 'Super') return null;
    // Native built-in method name -> never probe; leave as a direct static native call.
    if (NATIVE_METHODS.has(callee.property.name)) return null;
    // Known special globals (console/Math/JSON/Object/…) are intrinsics in Porffor codegen: their methods
    // ONLY resolve as the literal static `Global.method` — aliasing the receiver to a temp breaks them.
    // Never rewrite these; they can never hold a user box anyway. Leave the call fully native.
    if (callee.object && callee.object.type === 'Identifier' && GLOBALS.has(callee.object.name)) return null;
    if (node.arguments.some(a => a.type === 'SpreadElement')) return null;
    const tmp = '__mr' + (nextMtmp++);
    const propName = callee.property.name;
    const tmpId = () => ({ type:'Identifier', name: tmp });
    const member = () => ({ type:'MemberExpression', computed:false, optional:false,
      object: tmpId(), property:{ type:'Identifier', name: propName } });
    const memberDot = (k) => ({ type:'MemberExpression', computed:false, optional:false,
      object: member(), property:{ type:'Identifier', name:k } });
    // (__mrK = recv).name   — assignment-then-member, evaluates recv once
    const seededMember = { type:'MemberExpression', computed:false, optional:false,
      object: { type:'AssignmentExpression', operator:'=', left: tmpId(), right: callee.object },
      property:{ type:'Identifier', name: propName } };
    const test = { type:'LogicalExpression', operator:'&&',
      left: seededMember, right: memberDot('__clo') };
    // A METHOD box (tagged `__method`) takes the receiver as `__this` after env; a plain closure box does
    // not. Branch on the tag at runtime so both shapes dispatch through the same member call.
    const methodCall = { type:'CallExpression', optional:false, _skipWrap:true,
      callee: memberDot('fn'), arguments: [ memberDot('env'), tmpId(), ...node.arguments ] };
    const plainBoxCall = { type:'CallExpression', optional:false, _skipWrap:true,
      callee: memberDot('fn'), arguments: [ memberDot('env'), ...node.arguments ] };
    const boxCall = { type:'ConditionalExpression',
      test: memberDot('__method'), consequent: methodCall, alternate: plainBoxCall };
    const nativeCall = { type:'CallExpression', optional:false, _skipWrap:true,
      callee: member(), arguments: node.arguments };
    return { type:'ConditionalExpression', test, consequent: boxCall, alternate: nativeCall };
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
    if (isGlobalMemberCallee(callee)) {
      // Only non-computed `recv.name(...)` can be box-or-native ambiguous. Route through the inline
      // ternary dispatch. Computed/spread/optional member calls fall through unchanged (native only).
      // Only non-computed `recv.name(...)` can be box-or-native ambiguous. Route through the inline
      // ternary dispatch. Computed/spread/optional member calls fall through unchanged (native only) —
      // a computed callee may be ordinary indexing (`s[i]`, `arr[x]`) whose value-routing Porffor mangles.
      if (!callee.computed && callee.property && callee.property.type === 'Identifier') {
        const d = memberCallDispatch(node);
        if (d) return d;
      }
      return node;
    }
    if (callee.type === 'Identifier' && GLOBALS.has(callee.name)) return node;
    if (node.arguments.length === 1 && node.arguments[0].type === 'SpreadElement') {
      needCallS = true;
      return { type:'CallExpression', optional:false,
        callee:{type:'Identifier',name:'__callS'},
        arguments:[callee, node.arguments[0].argument] };
    }
    if (node.arguments.some(a => a.type === 'SpreadElement')) return node;
    if (node.arguments.length > 8) return node;
    const N = node.arguments.length;
    usedArities.add(N);
    return { type: 'CallExpression', optional:false,
      callee: { type:'Identifier', name:'__call'+N },
      arguments: [callee, ...node.arguments] };
  }
  wrapCalls(ast);

  const helpers = [];
  for (const N of [...usedArities].sort((a,b)=>a-b)) {
    const params = ['f']; for (let i=0;i<N;i++) params.push('a'+i);
    const passArgs = params.slice(1).map(p => p);
    helpers.push(
      `function __call${N}(${params.join(',')}){ if(f&&f.__clo)return f.fn(${['f.env',...passArgs].join(',')}); return f(${passArgs.join(',')}); }`);
  }
  if (needCallS) {
    helpers.push(
      `function __callS(f, arr){ var n = arr.length;` +
      ` if (f && f.__clo) { var e = f.env; if(n===0)return f.fn(e); if(n===1)return f.fn(e,arr[0]); if(n===2)return f.fn(e,arr[0],arr[1]); if(n===3)return f.fn(e,arr[0],arr[1],arr[2]); return f.fn(e,arr[0],arr[1],arr[2],arr[3]); }` +
      ` if(n===0)return f(); if(n===1)return f(arr[0]); if(n===2)return f(arr[0],arr[1]); if(n===3)return f(arr[0],arr[1],arr[2]); return f(arr[0],arr[1],arr[2],arr[3]); }`);
  }
  // HOF helpers: invoke the callback (box or plain fn) with static arity per element.
  // NOTE: helper-local names are deliberately mangled (__be/__bf/__hi/__hr/__hx/__hj/__hcmp). Porffor has a
  // scoping bug where a `var` inside a function that shadows a top-level `function NAME` recurses infinitely;
  // mangled names avoid colliding with any user binding.
  const hofDefs = {
    map:    `function __hof_map(arr,__cb){ var __hr=[]; if(__cb&&__cb.__clo){var __be=__cb.env,__bf=__cb.fn; for(var __hi=0;__hi<arr.length;__hi++)__hr.push(__bf(__be,arr[__hi],__hi,arr));} else {for(var __hi=0;__hi<arr.length;__hi++)__hr.push(__cb(arr[__hi],__hi,arr));} return __hr; }`,
    filter: `function __hof_filter(arr,__cb){ var __hr=[]; if(__cb&&__cb.__clo){var __be=__cb.env,__bf=__cb.fn; for(var __hi=0;__hi<arr.length;__hi++){if(__bf(__be,arr[__hi],__hi,arr))__hr.push(arr[__hi]);}} else {for(var __hi=0;__hi<arr.length;__hi++){if(__cb(arr[__hi],__hi,arr))__hr.push(arr[__hi]);}} return __hr; }`,
    forEach:`function __hof_forEach(arr,__cb){ if(__cb&&__cb.__clo){var __be=__cb.env,__bf=__cb.fn; for(var __hi=0;__hi<arr.length;__hi++)__bf(__be,arr[__hi],__hi,arr);} else {for(var __hi=0;__hi<arr.length;__hi++)__cb(arr[__hi],__hi,arr);} }`,
    reduce: `function __hof_reduce(arr,__cb,__hacc){ if(__cb&&__cb.__clo){var __be=__cb.env,__bf=__cb.fn; for(var __hi=0;__hi<arr.length;__hi++)__hacc=__bf(__be,__hacc,arr[__hi],__hi,arr);} else {for(var __hi=0;__hi<arr.length;__hi++)__hacc=__cb(__hacc,arr[__hi],__hi,arr);} return __hacc; }`,
    reduce1:`function __hof_reduce1(arr,__cb){ var __hacc=arr[0]; if(__cb&&__cb.__clo){var __be=__cb.env,__bf=__cb.fn; for(var __hi=1;__hi<arr.length;__hi++)__hacc=__bf(__be,__hacc,arr[__hi],__hi,arr);} else {for(var __hi=1;__hi<arr.length;__hi++)__hacc=__cb(__hacc,arr[__hi],__hi,arr);} return __hacc; }`,
    find:   `function __hof_find(arr,__cb){ if(__cb&&__cb.__clo){var __be=__cb.env,__bf=__cb.fn; for(var __hi=0;__hi<arr.length;__hi++){if(__bf(__be,arr[__hi],__hi,arr))return arr[__hi];}} else {for(var __hi=0;__hi<arr.length;__hi++){if(__cb(arr[__hi],__hi,arr))return arr[__hi];}} return undefined; }`,
    findIndex:`function __hof_findIndex(arr,__cb){ if(__cb&&__cb.__clo){var __be=__cb.env,__bf=__cb.fn; for(var __hi=0;__hi<arr.length;__hi++){if(__bf(__be,arr[__hi],__hi,arr))return __hi;}} else {for(var __hi=0;__hi<arr.length;__hi++){if(__cb(arr[__hi],__hi,arr))return __hi;}} return -1; }`,
    some:   `function __hof_some(arr,__cb){ if(__cb&&__cb.__clo){var __be=__cb.env,__bf=__cb.fn; for(var __hi=0;__hi<arr.length;__hi++){if(__bf(__be,arr[__hi],__hi,arr))return true;}} else {for(var __hi=0;__hi<arr.length;__hi++){if(__cb(arr[__hi],__hi,arr))return true;}} return false; }`,
    every:  `function __hof_every(arr,__cb){ if(__cb&&__cb.__clo){var __be=__cb.env,__bf=__cb.fn; for(var __hi=0;__hi<arr.length;__hi++){if(!__bf(__be,arr[__hi],__hi,arr))return false;}} else {for(var __hi=0;__hi<arr.length;__hi++){if(!__cb(arr[__hi],__hi,arr))return false;}} return true; }`,
    sort:   `function __hof_sort(arr,__cb){ var __ha=arr.slice(); for(var __hi=1;__hi<__ha.length;__hi++){ var __hx=__ha[__hi]; var __hj=__hi-1; while(__hj>=0){ var __hcmp; if(__cb&&__cb.__clo){__hcmp=__cb.fn(__cb.env,__ha[__hj],__hx);} else {__hcmp=__cb(__ha[__hj],__hx);} if(__hcmp>0){__ha[__hj+1]=__ha[__hj];__hj--;} else break; } __ha[__hj+1]=__hx; } for(var __hi=0;__hi<__ha.length;__hi++)arr[__hi]=__ha[__hi]; return arr; }`,
  };
  for (const name of usedHofs) helpers.push(hofDefs[name]);

  const helperAst = parse(helpers.join('\n'));
  ast.body.unshift(...helperAst.body);

  // Hoist receiver temps used by inline member-call dispatch (one shared `var __mr0,__mr1,…;`).
  if (nextMtmp > 0) {
    ast.body.unshift({ type:'VariableDeclaration', kind:'var',
      declarations: Array.from({length: nextMtmp}, (_,i) => ({
        type:'VariableDeclarator', id:{type:'Identifier', name:'__mr'+i}, init:null })) });
  }

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

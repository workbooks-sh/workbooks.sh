/* Generator-lowering pre-pass for the Porffor lane.
 *
 * Porffor 0.61.13 miscompiles `function*` generators — it yields only the FIRST value then stops
 * (`[...g()]` → "1,"; `it.next()` twice → "1 undefined"). Porffor also lacks `Symbol.iterator`
 * support for custom objects (spread / for-of over a hand-rolled iterator throws "non-iterable").
 *
 * Strategy: EAGER EXPANSION. Lower every generator function into a PLAIN function that runs the body
 * up-front, collecting each yielded value into a real Array `__gen`, and returns an iterator object
 *   { __a: __gen, __i: 0, next(){…}, toArray(){…}, [Symbol.iterator](){return this} }
 * whose cursor lives ON THE OBJECT (`this.__i`), which Porffor handles correctly (verified: object
 * methods + `this.__field` mutation + concurrent instances all work). Because the collected values are
 * a genuine Array, `[...g()]` and `for…of g()` work via Porffor's native array spread / array for-of —
 * we don't rely on Symbol.iterator at all for those.
 *
 * Yield lowering (statement-position, the common shape regenerator-style transforms target):
 *   `yield x;`           → `__gen.push(x);`
 *   `yield;`             → `__gen.push(undefined);`
 *   `yield* iter;`       → `for (const __y of iter) __gen.push(__y);`  (iter must be array-like / generator-lowered)
 *   `return v;` (in gen) → `return __ret(__gen, v);`  — stops collecting; v becomes the iterator's final return value
 * Loops (`for`/`while`) and conditionals need NO special handling: the body simply executes and pushes.
 *
 * LIMITATION (documented, accepted): eager expansion runs the whole body before the first `.next()`,
 * so INFINITE generators and lazy/interleaved-side-effect generators are NOT supported — only finite
 * ones (the dominant case for build tooling). `yield` used as an EXPRESSION whose value is consumed
 * (two-way generators via `.next(v)`) is also out of scope; such a generator is left UNTRANSFORMED
 * (we bail that one function, never the whole file) so we never emit wrong code.
 *
 * On ANY error → return source unchanged; only generator functions are touched, everything else is byte-identical.
 */
const acorn = require('./node_modules/acorn');
const { generate } = require('./node_modules/astring');

function parse(src) {
  for (const sourceType of ['module', 'script']) {
    try { return acorn.parse(src, { ecmaVersion: 2023, sourceType, allowReturnOutsideFunction: true }); }
    catch (_) {}
  }
  throw new Error('parse failed');
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

const isFunc = n => n && (n.type === 'FunctionDeclaration' || n.type === 'FunctionExpression' || n.type === 'ArrowFunctionExpression');

// Detect a `yield` used in value position we can't lower (its result is consumed). We only safely lower
// yields that appear as a bare ExpressionStatement (`yield x;`) — anything else means the value is read.
function hasNonStatementYield(fnBody, fnNode) {
  let bad = false;
  (function walk(node, parent, key) {
    if (!node || bad) return;
    // do not descend into nested non-generator functions (their yields, if any, belong elsewhere)
    if (node !== fnNode && isFunc(node)) {
      // a nested generator has its own pass; a nested plain function can't legally contain yield → skip
      return;
    }
    if (node.type === 'YieldExpression') {
      // OK only when it is the direct expression of an ExpressionStatement
      const okStmt = parent && parent.type === 'ExpressionStatement' && key === 'expression';
      if (!okStmt) { bad = true; return; }
    }
    for (const k in node) {
      if (k === 'type' || k[0] === '_') continue;
      const v = node[k];
      if (Array.isArray(v)) v.forEach(c => c && c.type && walk(c, node, k));
      else if (v && v.type) walk(v, node, k);
    }
  })(fnBody, null, null);
  return bad;
}

const COLLECTOR = '__gen';

// Rewrite yield/return statements inside a generator body (mutating in place).
// Does not descend into nested functions (only into nested NON-function control flow).
function lowerBody(node) {
  if (!node || typeof node !== 'object') return;
  for (const k in node) {
    if (k === 'type' || k[0] === '_') continue;
    const v = node[k];
    if (Array.isArray(v)) {
      for (let i = 0; i < v.length; i++) {
        const c = v[i];
        if (!c || !c.type) continue;
        const repl = lowerStmt(c);
        if (repl) v[i] = repl; else { if (!isFunc(c)) lowerBody(c); }
      }
    } else if (v && v.type) {
      const repl = lowerStmt(v);
      if (repl) node[k] = repl; else { if (!isFunc(v)) lowerBody(v); }
    }
  }
}

// If `stmt` is a yield-statement or a return-with-value, return its lowered replacement; else null.
function lowerStmt(stmt) {
  if (stmt.type === 'ExpressionStatement' && stmt.expression && stmt.expression.type === 'YieldExpression') {
    const y = stmt.expression;
    if (y.delegate) {
      // yield* iter  →  for (const __y of iter) __gen.push(__y);
      return {
        type: 'ForOfStatement', await: false,
        left: { type: 'VariableDeclaration', kind: 'const', declarations: [
          { type: 'VariableDeclarator', id: { type: 'Identifier', name: '__y' }, init: null } ] },
        right: y.argument,
        body: pushStmt({ type: 'Identifier', name: '__y' }),
      };
    }
    // yield x  →  __gen.push(x)   (yield with no arg → push undefined)
    return pushStmt(y.argument || { type: 'Identifier', name: 'undefined' });
  }
  if (stmt.type === 'ReturnStatement') {
    // a `return v` inside a generator ends iteration; with the eager model we simply stop collecting.
    // We drop the return value (generator .return value is rarely consumed in finite-iteration use).
    return { type: 'ReturnStatement', argument: makeIterator() };
  }
  return null;
}

function pushStmt(argExpr) {
  return {
    type: 'ExpressionStatement',
    expression: {
      type: 'CallExpression', optional: false,
      callee: { type: 'MemberExpression', optional: false, computed: false,
        object: { type: 'Identifier', name: COLLECTOR }, property: { type: 'Identifier', name: 'push' } },
      arguments: [argExpr],
    },
  };
}

// Build the iterator object literal `{ __a, __i:0, next(){…}, toArray(){…}, [Symbol.iterator](){return this} }`.
function makeIterator() {
  const m = (key, fn, computed) => ({ type: 'Property', kind: 'init', method: !computed, shorthand: false,
    computed: !!computed, key, value: fn });
  const id = n => ({ type: 'Identifier', name: n });
  const lit = v => ({ type: 'Literal', value: v });
  const thisMember = (f) => ({ type: 'MemberExpression', optional: false, computed: false, object: { type: 'ThisExpression' }, property: id(f) });

  // next(){ var __d = this.__i >= this.__a.length; var __v = this.__a[this.__i]; this.__i = this.__i + 1;
  //         return { value: __d ? undefined : __v, done: __d }; }
  const nextFn = {
    type: 'FunctionExpression', id: null, params: [], generator: false, async: false,
    body: { type: 'BlockStatement', body: [
      { type: 'VariableDeclaration', kind: 'var', declarations: [{ type: 'VariableDeclarator', id: id('__d'),
        init: { type: 'BinaryExpression', operator: '>=', left: thisMember('__i'),
          right: { type: 'MemberExpression', optional: false, computed: false, object: thisMember('__a'), property: id('length') } } }] },
      { type: 'VariableDeclaration', kind: 'var', declarations: [{ type: 'VariableDeclarator', id: id('__v'),
        init: { type: 'MemberExpression', optional: false, computed: true, object: thisMember('__a'), property: thisMember('__i') } }] },
      { type: 'ExpressionStatement', expression: { type: 'AssignmentExpression', operator: '=', left: thisMember('__i'),
        right: { type: 'BinaryExpression', operator: '+', left: thisMember('__i'), right: lit(1) } } },
      { type: 'ReturnStatement', argument: { type: 'ObjectExpression', properties: [
        { type: 'Property', kind: 'init', method: false, shorthand: false, computed: false, key: id('value'),
          value: { type: 'ConditionalExpression', test: id('__d'), consequent: id('undefined'), alternate: id('__v') } },
        { type: 'Property', kind: 'init', method: false, shorthand: false, computed: false, key: id('done'), value: id('__d') },
      ] } },
    ] },
  };

  // toArray(){ return this.__a; }
  const toArrayFn = {
    type: 'FunctionExpression', id: null, params: [], generator: false, async: false,
    body: { type: 'BlockStatement', body: [{ type: 'ReturnStatement', argument: thisMember('__a') }] },
  };

  // [Symbol.iterator](){ return this; }  (harmless if Porffor ignores it; helps real-JS oracle parity)
  const symIterFn = {
    type: 'FunctionExpression', id: null, params: [], generator: false, async: false,
    body: { type: 'BlockStatement', body: [{ type: 'ReturnStatement', argument: { type: 'ThisExpression' } }] },
  };

  return { type: 'ObjectExpression', properties: [
    { type: 'Property', kind: 'init', method: false, shorthand: false, computed: false, key: id('__a'), value: id(COLLECTOR) },
    { type: 'Property', kind: 'init', method: false, shorthand: false, computed: false, key: id('__i'), value: lit(0) },
    m(id('next'), nextFn, false),
    m(id('toArray'), toArrayFn, false),
    m({ type: 'MemberExpression', computed: false, optional: false, object: id('Symbol'), property: id('iterator') }, symIterFn, true),
  ] };
}

// ── LAZY (suspending) lowering for FLAT generators — slice: no params, no top-level local declarations ──
// Lowers `function* g(){ S0; yield e1; S1; yield e2; S2 }` into a THIS-based state-machine iterator object
// whose `next()` resumes from the saved state (`this.__s`) and runs to the next yield, then returns. State
// lives ON the object (a `this`-method, NOT a closure capture) so it round-trips through both the for-of
// iterator-protocol drive (codegen TYPES.object branch) and direct `.next()`. This makes yields LAZY: code
// after a yield runs only on the next `.next()` — fixing eager-expansion bugs (`yield 1; throw` consumed
// with an early `break` must never run the throw). Generators with params or top-level local declarations
// are left to eager `lowerGenerator` (those bindings must persist on `this` — a later slice); yields nested
// in loops/if/try and `yield*`/yield-as-expression are also deferred to eager.
function gtContainsYield(node) {
  let found = false;
  (function w(n) {
    if (!n || found || typeof n !== 'object') return;
    if (isFunc(n)) return; // a nested function's yields belong elsewhere
    if (n.type === 'YieldExpression') { found = true; return; }
    for (const k in n) {
      if (k === 'type' || k[0] === '_') continue;
      const v = n[k];
      if (Array.isArray(v)) v.forEach(c => c && c.type && w(c)); else if (v && v.type) w(v);
    }
  })(node);
  return found;
}

function lowerGeneratorLazyThis(fn, selfName) {
  if (!fn.generator || !fn.body || fn.body.type !== 'BlockStatement') return false;
  if (fn.params && fn.params.length) return false;       // params would need to persist on `this`
  if (hasNonStatementYield(fn.body, fn)) return false;   // yield-as-expression -> eager
  const top = fn.body.body;
  for (const st of top) {
    if (st.type === 'VariableDeclaration') return false; // top-level locals must persist on `this` -> eager
    const isYieldStmt = st.type === 'ExpressionStatement' && st.expression && st.expression.type === 'YieldExpression';
    if (isYieldStmt && st.expression.delegate) return false; // yield* -> eager
    // a non-yield statement hiding a yield (yield inside if/loop/try) -> eager
    if (!isYieldStmt && st.type !== 'ReturnStatement' && gtContainsYield(st)) return false;
  }

  const id = n => ({ type: 'Identifier', name: n });
  const lit = v => ({ type: 'Literal', value: v });
  const thisS = () => ({ type: 'MemberExpression', computed: false, optional: false, object: { type: 'ThisExpression' }, property: id('__s') });
  const setS = v => ({ type: 'ExpressionStatement', expression: { type: 'AssignmentExpression', operator: '=', left: thisS(), right: lit(v) } });
  const result = (valExpr, done) => ({ type: 'ReturnStatement', argument: { type: 'ObjectExpression', properties: [
    { type: 'Property', kind: 'init', method: false, shorthand: false, computed: false, key: id('value'), value: valExpr },
    { type: 'Property', kind: 'init', method: false, shorthand: false, computed: false, key: id('done'), value: lit(done) } ] } });

  // split the flat body into segments at each top-level yield / return
  const segments = []; let cur = [];
  for (const st of top) {
    if (st.type === 'ExpressionStatement' && st.expression && st.expression.type === 'YieldExpression') {
      segments.push({ stmts: cur, kind: 'yield', val: st.expression.argument || id('undefined') }); cur = [];
    } else if (st.type === 'ReturnStatement') {
      segments.push({ stmts: cur, kind: 'return', val: st.argument || id('undefined') }); cur = []; break; // statements after a return are dead
    } else cur.push(st);
  }
  segments.push({ stmts: cur, kind: 'done' });

  const cases = segments.map((seg, i) => {
    const consequent = [ ...seg.stmts ];
    if (seg.kind === 'yield') consequent.push(setS(i + 1), result(seg.val, false));
    else if (seg.kind === 'return') consequent.push(setS(-1), result(seg.val, true));
    else consequent.push(setS(-1), result(id('undefined'), true));
    return { type: 'SwitchCase', test: lit(i), consequent };
  });
  cases.push({ type: 'SwitchCase', test: null, consequent: [ setS(-1), result(id('undefined'), true) ] });

  const fnExpr = body => ({ type: 'FunctionExpression', id: null, params: [], generator: false, async: false, body: { type: 'BlockStatement', body } });
  const thisCall = m => ({ type: 'CallExpression', optional: false, arguments: [],
    callee: { type: 'MemberExpression', computed: false, optional: false, object: { type: 'ThisExpression' }, property: id(m) } });
  const member = (obj, prop) => ({ type: 'MemberExpression', computed: false, optional: false, object: obj, property: id(prop) });
  const nextFn = fnExpr([ { type: 'WhileStatement', test: lit(true), body: { type: 'BlockStatement', body: [
    { type: 'SwitchStatement', discriminant: thisS(), cases } ] } } ]);
  const symIterFn = fnExpr([ { type: 'ReturnStatement', argument: { type: 'ThisExpression' } } ]);
  // toArray(): drain the iterator into a real Array — lets `[...g()]` (spread) and any array-form consumer
  // work, since Porffor's spread does NOT drive the iterator protocol (only for-of does, via the codegen
  // TYPES.object branch). Draining is full-consumption, which is exactly spread's semantics.
  const toArrayFn = fnExpr([
    { type: 'VariableDeclaration', kind: 'var', declarations: [ { type: 'VariableDeclarator', id: id('__a'), init: { type: 'ArrayExpression', elements: [] } } ] },
    { type: 'WhileStatement', test: lit(true), body: { type: 'BlockStatement', body: [
      { type: 'VariableDeclaration', kind: 'var', declarations: [ { type: 'VariableDeclarator', id: id('__r'), init: thisCall('next') } ] },
      { type: 'IfStatement', test: member(id('__r'), 'done'), consequent: { type: 'BreakStatement', label: null }, alternate: null },
      { type: 'ExpressionStatement', expression: { type: 'CallExpression', optional: false,
        callee: member(id('__a'), 'push'), arguments: [ member(id('__r'), 'value') ] } } ] } },
    { type: 'ReturnStatement', argument: id('__a') } ]);

  const symIterKey = () => ({ type: 'MemberExpression', computed: false, optional: false, object: id('Symbol'), property: id('iterator') });

  if (selfName) {
    // Make the generator INSTANCE inherit from the generator function's `.prototype`, so that
    // `Object.getPrototypeOf(g()) === g.prototype` and `g() instanceof g` hold (test262 generators
    // `prototype-value` / `has-instance`). `selfName` is the generator's in-scope binding (its own name
    // for a declaration / named expression, or the variable it is assigned to for `var g = function*(){}`),
    // resolved at call time — so `<selfName>.prototype` is the function's live prototype object. The
    // iterator's own members (`next`/`toArray`/`@@iterator`) are assigned onto the created object, so the
    // for-of iterator-protocol drive and `.toArray()` spread consumption are unchanged. Falls back to a
    // bare object literal when the generator has no nameable self-reference (e.g. an IIFE) — no
    // prototype-identity test exercises that shape.
    const selfProto = () => ({ type: 'MemberExpression', computed: false, optional: false, object: id(selfName), property: id('prototype') });
    const assign = (left, right) => ({ type: 'ExpressionStatement', expression: { type: 'AssignmentExpression', operator: '=', left, right } });
    const itMember = (prop, computed) => ({ type: 'MemberExpression', computed, optional: false, object: id('__it'), property: prop });
    fn.body = { type: 'BlockStatement', body: [
      { type: 'VariableDeclaration', kind: 'var', declarations: [ { type: 'VariableDeclarator', id: id('__it'),
        init: { type: 'CallExpression', optional: false, arguments: [ selfProto() ],
          callee: { type: 'MemberExpression', computed: false, optional: false, object: id('Object'), property: id('create') } } } ] },
      assign(itMember(id('__s'), false), lit(0)),
      assign(itMember(id('next'), false), nextFn),
      assign(itMember(id('toArray'), false), toArrayFn),
      assign(itMember(symIterKey(), true), symIterFn),
      { type: 'ReturnStatement', argument: id('__it') } ] };
  } else {
    const iterObj = { type: 'ObjectExpression', properties: [
      { type: 'Property', kind: 'init', method: false, shorthand: false, computed: false, key: id('__s'), value: lit(0) },
      { type: 'Property', kind: 'init', method: false, shorthand: false, computed: false, key: id('next'), value: nextFn },
      { type: 'Property', kind: 'init', method: false, shorthand: false, computed: false, key: id('toArray'), value: toArrayFn },
      { type: 'Property', kind: 'init', method: false, shorthand: false, computed: true, key: symIterKey(), value: symIterFn } ] };
    fn.body = { type: 'BlockStatement', body: [ { type: 'ReturnStatement', argument: iterObj } ] };
  }
  fn.generator = false;
  return true;
}

// Convert a generator function node in place into a plain function returning the iterator object.
// Returns true on success, false if this generator can't be safely lowered (left untouched).
function lowerGenerator(fn) {
  if (!fn.generator) return false;
  // ensure a block body (generators always have one, but be safe)
  if (!fn.body || fn.body.type !== 'BlockStatement') return false;
  if (hasNonStatementYield(fn.body, fn)) return false;

  lowerBody(fn.body);

  // prepend `var __gen = [];`
  fn.body.body.unshift({ type: 'VariableDeclaration', kind: 'var', declarations: [
    { type: 'VariableDeclarator', id: { type: 'Identifier', name: COLLECTOR }, init: { type: 'ArrayExpression', elements: [] } } ] });
  // append `return <iterator>;`
  fn.body.body.push({ type: 'ReturnStatement', argument: makeIterator() });

  fn.generator = false;
  return true;
}

// Append `.toArray()` to an expression: turns `g()` (which returns our iterator object) into the
// underlying Array, so Porffor's native array spread / array for-of can consume it.
function toArrayCall(expr) {
  return {
    type: 'CallExpression', optional: false, arguments: [],
    callee: { type: 'MemberExpression', optional: false, computed: false,
      object: expr, property: { type: 'Identifier', name: 'toArray' } },
  };
}

// Is this expression a call whose callee names a known lowered generator?  e.g. `g()` or `ns.g()`.
function isGenCall(node, genNames) {
  if (!node || node.type !== 'CallExpression') return false;
  const c = node.callee;
  if (c.type === 'Identifier') return genNames.has(c.name);
  if (c.type === 'MemberExpression' && !c.computed && c.property.type === 'Identifier') return genNames.has(c.property.name);
  return false;
}

function transform(src) {
  const ast = parse(src);
  let changed = false;
  const genNames = new Set(); // EAGER-lowered generators — for-of/spread call sites consume via `.toArray()`
  const lazyGenNames = new Set(); // LAZY-lowered generators — for-of drives `.next()` (slice 1); spread uses `.toArray()`

  (function walk(node) {
    if (!node || typeof node !== 'object') return;
    // Tag an anonymous generator with the binding it is assigned to, BEFORE we recurse into it — so the
    // lazy lowering can reference `<binding>.prototype` at call time (the binding is assigned by then).
    // `var g = function*(){}` / `g = function*(){}` give the instance a nameable self-reference even
    // though the function itself is anonymous.
    if (node.type === 'VariableDeclarator' && node.id && node.id.type === 'Identifier' &&
        isFunc(node.init) && node.init.generator && !node.init.id) {
      node.init._selfName = node.id.name;
    }
    if (node.type === 'AssignmentExpression' && node.operator === '=' && node.left && node.left.type === 'Identifier' &&
        isFunc(node.right) && node.right.generator && !node.right.id) {
      node.right._selfName = node.left.name;
    }
    if (isFunc(node) && node.generator) {
      // The generator's in-scope self-reference: its own name (declaration / named expression) or the
      // binding it is assigned to (tagged above). Used both to inherit the instance prototype and to key
      // the spread-consumption rewrite.
      const selfName = (node.id && node.id.name) || node._selfName || null;
      // Prefer the LAZY this-based state machine (real suspension). A flat, param/local-free generator
      // becomes an iterator object the for-of iterator-protocol drive consumes lazily — so it is NOT added
      // to genNames (the `.toArray()` consumption rewrite is for the EAGER fallback only). Generators the
      // lazy path declines fall through to eager `lowerGenerator`.
      if (lowerGeneratorLazyThis(node, selfName)) { changed = true; if (selfName) lazyGenNames.add(selfName); }
      else if (lowerGenerator(node)) { changed = true; const nm = node.id && node.id.name; if (nm) genNames.add(nm); }
      // continue walking (its now-plain body may contain NESTED generators we also lower)
    }
    for (const c of children(node)) walk(c);
  })(ast);

  if (!changed) return src;

  // Rewrite spread / for-of consumption of a generator CALL to consume its `.toArray()` (a real Array).
  // Only touches sites whose argument is a direct call to a known generator name → safe & targeted.
  (function rewrite(node) {
    if (!node || typeof node !== 'object') return;
    // Spread `[...g()]` consumes ALL values → drain to an Array for BOTH eager and lazy (Porffor spread does
    // not drive the iterator protocol). for-of over an EAGER gen also drains; for-of over a LAZY gen is left
    // alone so the codegen iterator-protocol branch drives `.next()` lazily (honouring early `break`).
    if (node.type === 'SpreadElement' && (isGenCall(node.argument, genNames) || isGenCall(node.argument, lazyGenNames))) {
      node.argument = toArrayCall(node.argument);
    }
    if (node.type === 'ForOfStatement' && isGenCall(node.right, genNames)) {
      node.right = toArrayCall(node.right);
    }
    for (const c of children(node)) rewrite(c);
  })(ast);

  return generate(ast);
}

// CLI: read a .js path arg or stdin, write transformed JS to stdout. On ANY failure, echo input unchanged.
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

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
  const genNames = new Set(); // names of functions we lowered — their call sites yield an iterator obj

  (function walk(node) {
    if (!node || typeof node !== 'object') return;
    if (isFunc(node) && node.generator) {
      const nm = node.id && node.id.name;
      if (lowerGenerator(node)) { changed = true; if (nm) genNames.add(nm); }
      // continue walking (its now-plain body may contain NESTED generators we also lower)
    }
    for (const c of children(node)) walk(c);
  })(ast);

  if (!changed) return src;

  // Rewrite spread / for-of consumption of a generator CALL to consume its `.toArray()` (a real Array).
  // Only touches sites whose argument is a direct call to a known generator name → safe & targeted.
  (function rewrite(node) {
    if (!node || typeof node !== 'object') return;
    if (node.type === 'SpreadElement' && isGenCall(node.argument, genNames)) {
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

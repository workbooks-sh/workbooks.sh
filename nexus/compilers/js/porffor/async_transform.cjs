/* Async→then-chain (CPS) lowering pre-pass for the Porffor lane.
 *
 * Porffor compiles `async function` via the EAGER generator path and `await x` as a blocking
 * `__Porffor_promise_await(x)` that drives the microtask queue inline — so it never SUSPENDS, and
 * cross-async microtask ORDER diverges from node (an async body runs its post-await tail before the
 * synchronous code that follows the call). True await needs either stackful suspension (BEAM fibers) or
 * a continuation-passing transform. This pass does the latter, fully in-wasm: it rewrites an async
 * function into a PLAIN function that returns a Promise chain, splitting the body at each statement-level
 * `await` into a `.then` continuation. `Promise.resolve(X).then(cont)` defers `cont` exactly one microtask
 * (node's await semantics) and threads the resolved value — so ordering becomes byte-identical to node.
 *
 * This is only correct + possible because capturing `.then` callbacks now fire (the closure-box reaction
 * fix): each continuation captures the async body's locals.
 *
 *   async function f(a){ S0; await E1; S1; const x = await E2; S2; return R; }
 *     ⇩
 *   function f(a){ S0; return Promise.resolve(E1).then(function(){
 *                    S1; return Promise.resolve(E2).then(function(x){
 *                      S2; return R; }); }); }
 *
 * SUPPORTED (the dominant shape): awaits at STATEMENT position —
 *   `await E;`              (ExpressionStatement)
 *   `const/let/var x = await E;` (single declarator)
 *   `x = await E;`          (assignment)
 *   `return await E;` / `return E;`
 * in a flat BlockStatement body (including a trailing plain `return`).
 *
 * BAILED per-function (left async → Porffor's blocking fallback, documented gap, never miscompiled): an
 * `await` anywhere OTHER than those statement positions — inside an expression (`f(await x)`), a condition,
 * a loop/try/if body, or `for await`. Bailing one function never affects the rest of the file.
 *
 * On ANY error → return source unchanged.
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
    if (Array.isArray(v)) { for (const e of v) if (e && e.type) out.push(e); }
    else if (v && v.type) out.push(v);
  }
  return out;
}

// Does the subtree contain an AwaitExpression that belongs to THIS function (not a nested function)?
function hasOwnAwait(node) {
  if (!node || typeof node !== 'object') return false;
  if (node.type === 'AwaitExpression') return true;
  // do not descend into nested functions — their awaits are their own
  if (node.type === 'FunctionDeclaration' || node.type === 'FunctionExpression' || node.type === 'ArrowFunctionExpression') return false;
  for (const c of children(node)) if (hasOwnAwait(c)) return true;
  return false;
}

const id = (name) => ({ type: 'Identifier', name });

// Build `Promise.resolve(arg).then(function(<contParam?>){ <contBody> })`.
function thenChain(arg, contParam, contBody) {
  const params = contParam ? [contParam] : [];
  return {
    type: 'CallExpression', optional: false,
    callee: {
      type: 'MemberExpression', computed: false, optional: false,
      object: {
        type: 'CallExpression', optional: false,
        callee: { type: 'MemberExpression', computed: false, optional: false,
          object: id('Promise'), property: id('resolve') },
        arguments: [arg]
      },
      property: id('then')
    },
    arguments: [{ type: 'FunctionExpression', id: null, params, generator: false, async: false,
      body: { type: 'BlockStatement', body: contBody } }]
  };
}

// Classify a statement that introduces a top-level await. Returns {await: <expr>, bind: <pattern|null>} or
// null if this statement does not start with an await in a supported position.
function awaitStmt(stmt) {
  if (stmt.type === 'ExpressionStatement') {
    const e = stmt.expression;
    if (e.type === 'AwaitExpression') return { await: e.argument, bind: null };
    if (e.type === 'AssignmentExpression' && e.operator === '=' && e.right.type === 'AwaitExpression')
      return { await: e.right.argument, bind: e.left, assign: true };
  }
  if (stmt.type === 'VariableDeclaration' && stmt.declarations.length === 1) {
    const d = stmt.declarations[0];
    // any binding pattern: `const x = await E`, `const {a,b} = await E`, `const [x] = await E`.
    if (d.init && d.init.type === 'AwaitExpression')
      return { await: d.init.argument, bind: d.id, decl: stmt.kind };
  }
  if (stmt.type === 'ReturnStatement' && stmt.argument && stmt.argument.type === 'AwaitExpression')
    return { await: stmt.argument.argument, bind: null, ret: true };
  return null;
}

// CPS-lower a flat statement list. Throws BAIL if an await appears in an unsupported position.
function BAIL() { const e = new Error('bail'); e._bail = true; return e; }

function cpsList(stmts) {
  for (let i = 0; i < stmts.length; i++) {
    const s = stmts[i];
    const aw = awaitStmt(s);
    if (aw) {
      const pre = stmts.slice(0, i);
      const post = stmts.slice(i + 1);
      // the continuation body is the CPS lowering of everything after this await
      let contBody = cpsList(post);
      let contParam = null;
      if (aw.bind && aw.bind.type === 'Identifier' && !aw.assign && !aw.ret) {
        contParam = id(aw.bind.name);            // const x = await E  → function(x){…}
      } else if (aw.bind && aw.decl && !aw.assign && !aw.ret) {
        // const {a,b} = await E / const [x] = await E → function(__av){ const {a,b} = __av; … }
        contParam = id('__av' + i);
        contBody = [{ type: 'VariableDeclaration', kind: aw.decl,
          declarations: [{ type: 'VariableDeclarator', id: aw.bind, init: id('__av' + i) }] }, ...contBody];
      } else if (aw.assign) {
        contParam = id('__av' + i);              // x = await E → function(__av){ x = __av; … }
        contBody = [{ type: 'ExpressionStatement', expression: {
          type: 'AssignmentExpression', operator: '=', left: aw.bind, right: id('__av' + i) } }, ...contBody];
      }
      if (aw.ret) {
        // return await E  →  return Promise.resolve(E).then(function(__rv){ return __rv; })
        contParam = id('__rv' + i);
        contBody = [{ type: 'ReturnStatement', argument: id('__rv' + i) }];
      }
      const chain = thenChain(aw.await, contParam, contBody);
      return [...pre, { type: 'ReturnStatement', argument: chain }];
    }
    // a non-await statement that itself contains an own-await in a sub-position is unsupported
    if (hasOwnAwait(s)) throw BAIL();
  }
  return stmts;
}

function lowerAsyncFn(fn) {
  // body must be a block; an async arrow with expression body and an await → wrap
  let bodyStmts;
  if (fn.body.type === 'BlockStatement') bodyStmts = fn.body.body;
  else {
    if (fn.body.type === 'AwaitExpression') bodyStmts = [{ type: 'ReturnStatement', argument: fn.body }];
    else return; // async arrow, expr body, no await → leave to Porffor (it returns a proper promise)
  }
  // No await at all → leave async; Porffor's native async path already returns a correctly-resolved
  // promise (and converts a sync throw to a rejection). We only rewrite functions that actually suspend.
  if (!hasOwnAwait({ type: 'BlockStatement', body: bodyStmts })) return;
  const lowered = cpsList(bodyStmts);              // may throw BAIL
  fn.async = false;
  fn.body = { type: 'BlockStatement', body: lowered };
  // an arrow turned into a block body is no longer an expression
  if (fn.type === 'ArrowFunctionExpression') fn.expression = false;
}

function transform(src) {
  if (!/\basync\b/.test(src)) return src;
  const ast = parse(src);

  (function walk(node) {
    if (!node || typeof node !== 'object') return;
    if ((node.type === 'FunctionDeclaration' || node.type === 'FunctionExpression' ||
         node.type === 'ArrowFunctionExpression') && node.async && !node.generator) {
      // lower nested functions FIRST (inner awaits belong to inner fns), then this one
      for (const c of children(node.body)) walk(c);
      try { lowerAsyncFn(node); } catch (e) { if (!e._bail) throw e; /* leave async untouched */ }
      return;
    }
    for (const c of children(node)) walk(c);
  })(ast);

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

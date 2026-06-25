/* Closure-promotion pre-pass for the Porffor lane (wb-akrf).
 *
 * Porffor 0.61 has no closure capture: a nested function referencing an enclosing function's local
 * throws "x is not defined" / reads garbage. This pass rewrites SINGLE-INSTANCE captures into module
 * GLOBALS, which Porffor resolves across scopes — correct for non-reentrant closures (the dominant
 * module-level / factory pattern: counter, curry, higher-order). It does NOT fix per-iteration multi-
 * instance captures (e.g. `for(let i) ()=>i`) — those share one global; left for true closure conversion.
 *
 * Strategy: find every binding (param / let / const / var in a function scope) that is referenced from a
 * DEEPER function scope. Promote it to a top-level `var __cap_N`; rewrite the declaration to an assignment
 * (locals) or inject `__cap_N = param` at the function body start (params, converting an expression-body
 * arrow to a block); rename all of the binding's references to `__cap_N`. On any error → return source
 * unchanged (the caller still compiles via Porffor; worst case is the original miscompile, never worse).
 */
const acorn = require('./node_modules/acorn');
const { generate } = require('./node_modules/astring');

const BUILTINS = new Set(['console', 'Math', 'JSON', 'Object', 'Array', 'String', 'Number', 'Boolean',
  'Symbol', 'Map', 'Set', 'Promise', 'Error', 'TypeError', 'RangeError', 'parseInt', 'parseFloat',
  'isNaN', 'undefined', 'NaN', 'Infinity', 'globalThis', 'Function', 'RegExp', 'Date', 'BigInt']);

function parse(src) {
  for (const sourceType of ['module', 'script']) {
    try { return acorn.parse(src, { ecmaVersion: 2023, sourceType, allowReturnOutsideFunction: true }); }
    catch (_) {}
  }
  throw new Error('parse failed');
}

const isFunc = n => n && (n.type === 'FunctionDeclaration' || n.type === 'FunctionExpression' || n.type === 'ArrowFunctionExpression');

// collect the identifier names bound by a pattern (params / declarators)
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

// collect the binding-position Identifier NODES of a pattern (so the walk can skip them — only
// REFERENCES get renamed, never the binding occurrence itself).
function patternIdentNodes(node, set) {
  if (!node) return;
  switch (node.type) {
    case 'Identifier': set.add(node); break;
    case 'RestElement': patternIdentNodes(node.argument, set); break;
    case 'AssignmentPattern': patternIdentNodes(node.left, set); break; // default VALUE stays a reference
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

  // ── scope analysis: each function scope tracks its bindings; resolve references to bindings, flagging
  // a capture when a reference's function scope is deeper than the binding's owning function scope. ──
  let nextId = 0;
  const bindings = new Map(); // bindingObj.id -> {name, declNode, ownerFunc, kind, refs:[], captured, gname}
  const bindingNodes = new Set(); // Identifier NODES in binding positions — never renamed as references

  function makeScope(funcNode, parent) {
    return { funcNode, parent, vars: new Map() };
  }

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

  // hoist declarations into a scope (params at function entry; var/function hoist to function scope;
  // let/const are block-ish but we keep one flat function scope — close enough for capture detection).
  function collectDecls(node, scope) {
    for (const c of children(node)) {
      if (isFunc(c)) continue; // nested functions get their own scope pass
      if (c.type === 'VariableDeclaration') {
        for (const d of c.declarations) {
          patternIdentNodes(d.id, bindingNodes);
          const names = []; patternNames(d.id, names);
          for (const nm of names) if (!scope.vars.has(nm)) { const b = declare(scope, nm, d, c.kind); b.declStmt = c; }
        }
      }
      if (c.type === 'FunctionDeclaration' && c.id) {
        bindingNodes.add(c.id);
        if (!scope.vars.has(c.id.name)) declare(scope, c.id.name, c, 'var');
      }
      collectDecls(c, scope);
    }
  }

  function walk(node, scope) {
    // open a new function scope
    if (isFunc(node)) {
      const child = makeScope(node, scope);
      const pnames = [];
      for (const p of node.params) { patternNames(p, pnames); patternIdentNodes(p, bindingNodes); }
      for (const nm of pnames) declare(child, nm, node, 'param');
      collectDecls(node.body, child);
      if (node.id) bindingNodes.add(node.id);
      for (const c of children(node)) walk(c, child);
      return;
    }

    // identifier REFERENCE — skip binding occurrences (params, declarator ids, fn names)
    if (node.type === 'Identifier') {
      if (bindingNodes.has(node)) return;
      const b = resolve(scope, node.name);
      if (b) {
        b.refs.push(node);
        if (scope.funcNode !== b.ownerFunc && b.ownerFunc != null) b.captured = true;
      }
      return;
    }

    // skip non-computed member property + non-computed object keys (not references)
    if (node.type === 'MemberExpression') {
      walk(node.object, scope);
      if (node.computed) walk(node.property, scope);
      return;
    }
    if (node.type === 'Property' && !node.computed && node.key && node.key.type === 'Identifier') {
      walk(node.value, scope);
      return;
    }

    for (const c of children(node)) walk(c, scope);
  }

  const top = makeScope(null, null); // module scope (funcNode null = "global")
  collectDecls(ast, top);
  for (const c of children(ast)) walk(c, top);

  // tag for-init/for-of/for-in VariableDeclarations — those bindings are per-iteration and must NOT be
  // promoted to a single global (would collapse multi-instance loop closures); skip them entirely.
  (function tagForInits(node) {
    if (!node) return;
    if (node.type === 'ForStatement' && node.init && node.init.type === 'VariableDeclaration') node.init._forInit = true;
    if ((node.type === 'ForInStatement' || node.type === 'ForOfStatement') && node.left && node.left.type === 'VariableDeclaration') node.left._forInit = true;
    for (const c of children(node)) tagForInits(c);
  })(ast);

  // a binding is promotable iff: a param, OR a function-local declared by a single-declarator,
  // initialised, statement-level (non-for-init) VariableDeclaration we can rewrite to a global assignment.
  const promotable = b =>
    b.captured && b.ownerFunc != null &&
    (b.kind === 'param' ||
      (b.declStmt && !b.declStmt._forInit && b.declStmt.declarations.length === 1 && b.declStmt.declarations[0].init != null));

  const captured = [...bindings.values()].filter(promotable);
  if (captured.length === 0) return src;

  const globalDecls = [];
  for (const b of captured) {
    b.gname = `__cap_${b.id}_${b.name}`;
    globalDecls.push(b.gname);
    for (const r of b.refs) r.name = b.gname; // rename every reference

    if (b.kind === 'param') {
      // seed the global from the param at the owning function's body start (block-convert expr arrows).
      const fn = b.ownerFunc;
      if (fn.body.type !== 'BlockStatement') {
        fn.body = { type: 'BlockStatement', body: [{ type: 'ReturnStatement', argument: fn.body }] };
        fn.expression = false;
      }
      fn.body.body.unshift({
        type: 'ExpressionStatement',
        expression: { type: 'AssignmentExpression', operator: '=',
          left: { type: 'Identifier', name: b.gname }, right: { type: 'Identifier', name: b.name } }
      });
    } else {
      // local: rewrite `let v = init` IN PLACE into `gname = init` (a global assignment — gname is
      // declared `var` at module top). Mutating the node object is what astring re-emits.
      const init = b.declStmt.declarations[0].init;
      b.declStmt.type = 'ExpressionStatement';
      b.declStmt.expression = { type: 'AssignmentExpression', operator: '=',
        left: { type: 'Identifier', name: b.gname }, right: init };
      delete b.declStmt.declarations;
      delete b.declStmt.kind;
    }
  }

  // prepend `var __cap_…;` declarations at module top
  ast.body.unshift({
    type: 'VariableDeclaration', kind: 'var',
    declarations: globalDecls.map(n => ({ type: 'VariableDeclarator', id: { type: 'Identifier', name: n }, init: null }))
  });

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
main();

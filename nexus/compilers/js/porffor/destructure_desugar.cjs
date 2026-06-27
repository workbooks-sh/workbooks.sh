/* Object-destructuring desugar for the Porffor lane.
 *
 * Porffor 0.61 miscompiles a MULTI-PROPERTY object-pattern binding in a deep/boxed
 * context: `const { a: x, b: y } = obj` leaves the EARLIER target(s) bound to undefined
 * (the lowering reuses a temp that clobbers the first reads). Single-property patterns and
 * shallow top-level patterns happen to work, so the bug only surfaces at scale inside a
 * closure-converted CPS continuation (e.g. rollupInternal's
 * `const { options: inputOptions, unsetOptions } = await getInputOptions(...)` → inputOptions
 * came out undefined → `initialiseTimers(undefined)` → "Cannot read property 'perf' of undefined").
 *
 * Fix (what Babel does too): lower each object-pattern declarator to a single temp plus one
 * member read per property — a form Porffor compiles correctly:
 *
 *   const { a: x, b = 1, [k]: c } = E;
 *   =>
 *   const __destr_0 = E;
 *   const x = __destr_0.a;
 *   const b = __destr_0.b === undefined ? 1 : __destr_0.b;
 *   const c = __destr_0[k];
 *
 * The init is evaluated ONCE into the temp (side-effect-preserving). We desugar conservatively:
 * only top-level object patterns in declarators, BAILING (leaving the declarator untouched) on
 * nested patterns and rest elements, which are rarer and out of scope. Array patterns are left
 * alone (they lower fine). On any parse/transform error the source is returned UNCHANGED.
 *
 * Porffor ALSO miscompiles a destructuring ASSIGNMENT (`({a: x, b: this.y} = E)` / `[a, b] = E`,
 * vs a declaration) inside a CLASS METHOD — it throws "undefined is not defined" (a ReferenceError on
 * an unresolved internal name). The same assignment works in a plain function, an object method, or
 * top level, so it's a scope-specific codegen gap. rollup's ModuleLoader hits it:
 * `({entryModules: this.entryModules, implicitEntryModules: this.implicitEntryModules} =
 * await this.generateModuleGraph())` inside a class method's async continuation. Lower a
 * STATEMENT-context pattern assignment the same way (one temp + one plain assignment per target),
 * which Porffor compiles everywhere. Targets may be Identifiers or MemberExpressions (`this.x`);
 * defaults handled; rest/nested patterns BAIL (left untouched).
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

// Walk every node, invoking visit(node, parent, key). Mirrors map_desugar's walker.
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

const ident = (name) => ({ type: 'Identifier', name });
const member = (obj, prop, computed) => ({
  type: 'MemberExpression', computed: !!computed, optional: false, object: obj, property: prop
});

// Can we cleanly desugar this object pattern? Only simple property targets (Identifier or
// `Identifier = default`); no nested object/array patterns, no rest element.
function isSimpleObjectPattern(pat) {
  if (!pat || pat.type !== 'ObjectPattern') return false;
  for (const p of pat.properties) {
    if (p.type === 'RestElement') return false;
    if (p.type !== 'Property') return false;
    const v = p.value;
    if (v.type === 'Identifier') continue;
    if (v.type === 'AssignmentPattern' && v.left.type === 'Identifier') continue;
    return false; // nested pattern target
  }
  return true;
}

// An assignment-destructuring target is simple if every leaf is an Identifier or MemberExpression
// (e.g. `this.x`), optionally with a default (AssignmentPattern). Nested patterns / rest → bail.
const isSimpleAssignTarget = (t) => t && (t.type === 'Identifier' || t.type === 'MemberExpression');
function isSimpleAssignObjectPattern(pat) {
  if (!pat || pat.type !== 'ObjectPattern') return false;
  for (const p of pat.properties) {
    if (p.type !== 'Property') return false; // RestElement etc.
    const v = p.value;
    if (isSimpleAssignTarget(v)) continue;
    if (v.type === 'AssignmentPattern' && isSimpleAssignTarget(v.left)) continue;
    return false;
  }
  return true;
}
function isSimpleAssignArrayPattern(pat) {
  if (!pat || pat.type !== 'ArrayPattern') return false;
  for (const e of pat.elements) {
    if (e === null) continue; // hole
    if (isSimpleAssignTarget(e)) continue;
    if (e.type === 'AssignmentPattern' && isSimpleAssignTarget(e.left)) continue;
    return false; // RestElement / nested
  }
  return true;
}

// Build `target = read` (or `target = read === undefined ? default : read` for a default).
function assignFrom(target, read) {
  let tgt = target, init = read;
  if (target.type === 'AssignmentPattern') {
    tgt = target.left;
    init = { type: 'ConditionalExpression',
      test: { type: 'BinaryExpression', operator: '===', left: read, right: ident('undefined') },
      consequent: target.right, alternate: read };
  }
  return { type: 'ExpressionStatement', expression: {
    type: 'AssignmentExpression', operator: '=', left: tgt, right: init } };
}

function transform(src) {
  const ast = parse(src);
  let counter = 0;
  let touched = false;

  // Pass: lower STATEMENT-context destructuring ASSIGNMENTS `({...} = E);` / `[...] = E;` to a temp
  // plus per-target assignments. Only when the statement lives in a spliceable statement list.
  walk(ast, null, null, (node, parent, key) => {
    if (node.type !== 'ExpressionStatement') return;
    const e = node.expression;
    if (!e || e.type !== 'AssignmentExpression' || e.operator !== '=') return;
    const lhs = e.left;
    const isObj = isSimpleAssignObjectPattern(lhs);
    const isArr = !isObj && isSimpleAssignArrayPattern(lhs);
    if (!isObj && !isArr) return;
    if (!Array.isArray(parent && parent[key])) return;

    const tmp = '__destr_' + (counter++);
    const out = [{ type: 'VariableDeclaration', kind: 'var',
      declarations: [{ type: 'VariableDeclarator', id: ident(tmp), init: e.right }] }];
    if (isObj) {
      for (const p of lhs.properties) {
        const keyExpr = p.computed ? p.key : (p.key.type === 'Identifier' ? ident(p.key.name) : p.key);
        out.push(assignFrom(p.value, member(ident(tmp), keyExpr, p.computed)));
      }
    } else {
      lhs.elements.forEach((el, i) => {
        if (el === null) return; // hole
        out.push(assignFrom(el, member(ident(tmp), { type: 'Literal', value: i }, true)));
      });
    }
    const list = parent[key];
    const idx = list.indexOf(node);
    if (idx >= 0) { list.splice(idx, 1, ...out); touched = true; }
  });

  // Replace each VariableDeclaration that contains a desugarable object-pattern declarator with a
  // sequence of plain declarations. We mutate the statement's parent array in place.
  walk(ast, null, null, (node, parent, key) => {
    if (node.type !== 'VariableDeclaration') return;
    if (!Array.isArray(parent && parent[key])) return; // must live in a statement list we can splice
    // Does any declarator need desugaring?
    if (!node.declarations.some((d) => isSimpleObjectPattern(d.id))) return;

    const out = [];
    for (const d of node.declarations) {
      if (!isSimpleObjectPattern(d.id) || !d.init) {
        out.push({ type: 'VariableDeclaration', kind: node.kind, declarations: [d] });
        continue;
      }
      const tmp = '__destr_' + (counter++);
      out.push({
        type: 'VariableDeclaration', kind: node.kind,
        declarations: [{ type: 'VariableDeclarator', id: ident(tmp), init: d.init }]
      });
      for (const p of d.id.properties) {
        const keyExpr = p.computed ? p.key : (p.key.type === 'Identifier' ? ident(p.key.name) : p.key);
        const read = member(ident(tmp), keyExpr, p.computed);
        let target, init;
        if (p.value.type === 'AssignmentPattern') {
          target = p.value.left;
          init = {
            type: 'ConditionalExpression',
            test: { type: 'BinaryExpression', operator: '===', left: read, right: ident('undefined') },
            consequent: p.value.right,
            alternate: read
          };
        } else {
          target = p.value;
          init = read;
        }
        out.push({
          type: 'VariableDeclaration', kind: node.kind,
          declarations: [{ type: 'VariableDeclarator', id: target, init }]
        });
      }
    }
    // Splice the expansion into the parent statement list in place of `node`.
    const list = parent[key];
    const idx = list.indexOf(node);
    if (idx >= 0) { list.splice(idx, 1, ...out); touched = true; }
  });

  if (!touched) return src;
  return generate(ast);
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

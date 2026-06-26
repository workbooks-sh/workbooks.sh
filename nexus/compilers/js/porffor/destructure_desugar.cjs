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

function transform(src) {
  const ast = parse(src);
  let counter = 0;
  let touched = false;

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

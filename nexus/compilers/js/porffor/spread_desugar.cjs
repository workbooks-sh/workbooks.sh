/* Spread-into-call pre-pass for the Porffor lane.
 *
 * Porffor 0.61 handles spread into user functions and ordinary (non-comptime) builtins via an
 * 8-slot expansion, but spread into a *comptime* builtin (Math.max / Math.min) reaches the comptime
 * generator with a raw SpreadElement in `decl.arguments` => "porffor: no generation for SpreadElement".
 * The 8-slot path also can't help comptime builtins (it would read out-of-bounds undefined slots).
 *
 * This pass rewrites the comptime-min/max spread forms into a runtime `reduce`, which is correct for
 * ANY element count and any (static or dynamic) array:
 *
 *   Math.max(...arr)            -> (arr).reduce((__a,__b)=> __a>__b?__a:__b, -Infinity)
 *   Math.min(...arr)            -> (arr).reduce((__a,__b)=> __a<__b?__a:__b,  Infinity)
 *   Math.max(x, ...arr, y)      -> ([x].concat(arr, [y])).reduce(... , -Infinity)
 *
 * Every other spread (user funcs, array/object literals, ordinary builtins) is left untouched — those
 * already compile correctly. On any error the source is returned unchanged (safe fallback).
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

const id = name => ({ type: 'Identifier', name });
const lit = value => ({ type: 'Literal', value });

// -Infinity / Infinity as UnaryExpression / Identifier (astring-friendly)
const negInf = () => ({ type: 'UnaryExpression', operator: '-', prefix: true, argument: id('Infinity') });
const posInf = () => id('Infinity');

// reducer arrow: (__a,__b) => __a OP __b ? __a : __b
function reducer(op) {
  return {
    type: 'ArrowFunctionExpression', params: [id('__mr_a'), id('__mr_b')], expression: true, async: false, generator: false,
    body: {
      type: 'ConditionalExpression',
      test: { type: 'BinaryExpression', operator: op, left: id('__mr_a'), right: id('__mr_b') },
      consequent: id('__mr_a'), alternate: id('__mr_b')
    }
  };
}

// Build a single array expression from the call arguments, turning spreads into .concat segments.
// Returns an AST node that evaluates to a plain array of all the numbers.
function argsToArray(args) {
  // Fast path: exactly one arg and it's a spread -> just the spread argument (already an array/iterable)
  if (args.length === 1 && args[0].type === 'SpreadElement') return args[0].argument;

  // General: head literal elements until first spread, then .concat the rest
  // [a, b].concat(spreadArg, [c], spreadArg2, ...)
  const segments = [];
  let current = [];
  for (const a of args) {
    if (a.type === 'SpreadElement') {
      if (current.length) { segments.push({ type: 'ArrayExpression', elements: current }); current = []; }
      segments.push(a.argument);
    } else {
      current.push(a);
    }
  }
  if (current.length) segments.push({ type: 'ArrayExpression', elements: current });

  if (segments.length === 1) return segments[0].type === 'ArrayExpression' ? segments[0] : segments[0];
  const base = segments[0].type === 'ArrayExpression' ? segments[0] : { type: 'ArrayExpression', elements: [] };
  const rest = segments[0].type === 'ArrayExpression' ? segments.slice(1) : segments;
  return {
    type: 'CallExpression', optional: false,
    callee: { type: 'MemberExpression', computed: false, optional: false, object: base, property: id('concat') },
    arguments: rest
  };
}

function makeReduce(arrNode, op, init) {
  return {
    type: 'CallExpression', optional: false,
    callee: { type: 'MemberExpression', computed: false, optional: false, object: arrNode, property: id('reduce') },
    arguments: [reducer(op), init]
  };
}

// is callee Math.max / Math.min ?
function mathExtreme(callee) {
  if (!callee || callee.type !== 'MemberExpression' || callee.computed) return null;
  if (callee.object.type !== 'Identifier' || callee.object.name !== 'Math') return null;
  if (callee.property.type !== 'Identifier') return null;
  if (callee.property.name === 'max') return { op: '>', init: negInf() };
  if (callee.property.name === 'min') return { op: '<', init: posInf() };
  return null;
}

function hasSpread(args) { return args.some(a => a.type === 'SpreadElement'); }

function walk(node, visit) {
  if (!node || typeof node !== 'object') return;
  visit(node);
  for (const k in node) {
    if (k === 'type' || k[0] === '_') continue;
    const v = node[k];
    if (Array.isArray(v)) { for (const c of v) if (c && typeof c.type === 'string') walk(c, visit); }
    else if (v && typeof v.type === 'string') walk(v, visit);
  }
}

// is callee  <expr>.replace / <expr>.replaceAll  with non-regexp string args?
// We only desugar when the search arg is NOT a regexp literal and the replacement
// is NOT a function (the broken-but-common string,string form). Otherwise leave it.
function replaceKind(node) {
  const c = node.callee;
  if (!c || c.type !== 'MemberExpression' || c.computed) return null;
  if (c.property.type !== 'Identifier') return null;
  const name = c.property.name;
  if (name !== 'replace' && name !== 'replaceAll') return null;
  const args = node.arguments;
  if (args.length < 2) return null;
  if (args.some(a => a.type === 'SpreadElement')) return null;
  const search = args[0], repl = args[1];
  // skip regexp search (RegExp literal or `new RegExp`) and function replacement
  if (search.type === 'Literal' && search.regex) return null;
  if (repl.type === 'ArrowFunctionExpression' || repl.type === 'FunctionExpression') return null;
  return { all: name === 'replaceAll', object: c.object, search, repl };
}

// <expr>.replace(/re/g, "literal") — Porffor's native regexp replace is broken, but split+join is
// equivalent for a GLOBAL regex with a plain-string replacement (no $ backrefs / no function): the
// working `.split(regex)` + `.join(str)` compose, e.g. 'a1b2c3'.split(/[0-9]/).join('#') = 'a#b#c#'.
function regexReplaceKind(node) {
  const c = node.callee;
  if (!c || c.type !== 'MemberExpression' || c.computed) return null;
  if (c.property.type !== 'Identifier' || c.property.name !== 'replace') return null;
  const args = node.arguments;
  if (args.length < 2) return null;
  const search = args[0], repl = args[1];
  if (!(search.type === 'Literal' && search.regex && /g/.test(search.regex.flags))) return null;
  if (repl.type !== 'Literal' || typeof repl.value !== 'string') return null;
  if (/\$[0-9&$`']/.test(repl.value)) return null; // $-backref/special — leave to native
  return { object: c.object, search, repl };
}

// __porf_replace(str, search, repl, all): first-or-all literal-string replacement,
// implemented with indexOf/slice/concat (all of which work in Porffor 0.61).
const REPLACE_HELPER = `function __porf_replace(__s, __q, __r, __all){
  __s = '' + __s; __q = '' + __q; __r = '' + __r;
  if (__q === '') return __all ? __s : (__r + __s);
  var __out = ''; var __from = 0;
  while (true) {
    var __i = __s.indexOf(__q, __from);
    if (__i < 0) { __out = __out + __s.slice(__from); break; }
    __out = __out + __s.slice(__from, __i) + __r;
    __from = __i + __q.length;
    if (!__all) { __out = __out + __s.slice(__from); break; }
  }
  return __out;
}`;

function transform(src) {
  let ast;
  try { ast = parse(src); } catch (_) { return src; }
  try {
    let usedReplace = false;
    walk(ast, node => {
      if (node.type !== 'CallExpression') return;

      // Math.max/min spread -> reduce
      const m = mathExtreme(node.callee);
      if (m && hasSpread(node.arguments)) {
        const arr = argsToArray(node.arguments);
        const reduced = makeReduce(arr, m.op, m.init);
        for (const k of Object.keys(node)) delete node[k];
        Object.assign(node, reduced);
        return;
      }

      // <expr>.replace(/re/g, "str") -> <expr>.split(/re/).join("str")
      const grk = regexReplaceKind(node);
      if (grk) {
        // split must use a NON-global regex — Porffor's split mishandles the /g flag (splits only
        // first/last); split ignores /g per spec anyway, so strip it.
        const splitRe = { type: 'Literal', value: null,
          regex: { pattern: grk.search.regex.pattern, flags: grk.search.regex.flags.replace(/g/g, '') } };
        const splitCall = { type: 'CallExpression', optional: false,
          callee: { type: 'MemberExpression', computed: false, optional: false, object: grk.object, property: id('split') },
          arguments: [splitRe] };
        const joinCall = { type: 'CallExpression', optional: false,
          callee: { type: 'MemberExpression', computed: false, optional: false, object: splitCall, property: id('join') },
          arguments: [grk.repl] };
        for (const k of Object.keys(node)) delete node[k];
        Object.assign(node, joinCall);
        return;
      }

      // String#replace / replaceAll (string,string) -> __porf_replace(...)
      const rk = replaceKind(node);
      if (rk) {
        usedReplace = true;
        const call = {
          type: 'CallExpression', optional: false, callee: id('__porf_replace'),
          arguments: [rk.object, rk.search, rk.repl, lit(rk.all)]
        };
        for (const k of Object.keys(node)) delete node[k];
        Object.assign(node, call);
      }
    });

    let out = generate(ast);
    if (usedReplace) out = REPLACE_HELPER + '\n' + out;
    return out;
  } catch (_) {
    return src;
  }
}

module.exports = { transform };

if (require.main === module) {
  const fs = require('fs');
  const input = fs.readFileSync(process.argv[2] || 0, 'utf8');
  process.stdout.write(transform(input));
}

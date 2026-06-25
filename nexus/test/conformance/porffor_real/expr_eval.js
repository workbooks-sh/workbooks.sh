function evalExpr(s) {
  let i = 0;
  const peek = () => s[i], next = () => s[i++];
  function num() { let n=''; while(i<s.length && /[0-9]/.test(peek())) n+=next(); return +n; }
  function factor() { if (peek()==='('){next(); const v=expr(); next(); return v;} return num(); }
  function term() { let v=factor(); while(peek()==='*'||peek()==='/'){const op=next(); const r=factor(); v=op==='*'?v*r:v/r;} return v; }
  function expr() { let v=term(); while(peek()==='+'||peek()==='-'){const op=next(); const r=term(); v=op==='+'?v+r:v-r;} return v; }
  return expr();
}
console.log(evalExpr('2+3*4'), evalExpr('(2+3)*4'), evalExpr('10-2*3'));

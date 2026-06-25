// Heavy dynamic dispatch (Box<dyn Trait> → call_indirect) + recursion, SELF-VERIFYING.
trait Expr { fn eval(&self) -> i64; }
struct Lit(i64);
struct Add(Box<dyn Expr>, Box<dyn Expr>);
struct Mul(Box<dyn Expr>, Box<dyn Expr>);
impl Expr for Lit { fn eval(&self) -> i64 { self.0 } }
impl Expr for Add { fn eval(&self) -> i64 { self.0.eval().wrapping_add(self.1.eval()) } }
impl Expr for Mul { fn eval(&self) -> i64 { self.0.eval().wrapping_mul(self.1.eval()) } }
fn main() {
    // 1000 trait objects, each dispatched via vtable; compare to an inline (non-dispatch) computation.
    let mut ok = true;
    for i in 0..1000i64 {
        let (boxed, expected): (Box<dyn Expr>, i64) = if i % 2 == 0 {
            (Box::new(Add(Box::new(Lit(i)), Box::new(Lit(i)))), i.wrapping_add(i))
        } else {
            (Box::new(Mul(Box::new(Lit(i)), Box::new(Lit(3)))), i.wrapping_mul(3))
        };
        if boxed.eval() != expected { ok = false; }
    }
    // deep recursive tree dispatched entirely through vtables; just require it terminates + is stable.
    fn build(d: u32) -> Box<dyn Expr> {
        if d == 0 { Box::new(Lit(1)) }
        else if d % 2 == 0 { Box::new(Add(build(d-1), build(d-1))) }
        else { Box::new(Mul(build(d-1), build(d-1))) }
    }
    let t = build(14);
    let a = t.eval();
    let b = t.eval();
    std::process::exit(if ok && a == b { 42 } else { 1 });
}

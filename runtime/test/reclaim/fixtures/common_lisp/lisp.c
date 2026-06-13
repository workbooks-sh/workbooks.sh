/* A self-contained ANSI-Common-Lisp-SUBSET interpreter in C.
 *
 * Reads one or more s-expressions from stdin, evaluates them in sequence in a
 * lexically-scoped global+local environment, and prints the value of the LAST
 * top-level form. Supports:
 *   - reader: integers, symbols, lists, quote ('x), nil, t
 *   - data: cons cells (car/cdr), interned symbols, integers
 *   - special forms: quote, if, cond, lambda, defun, define, setq, let, progn
 *   - primitives: + - * = < > cons car cdr atom null list eq not
 *   - closures with captured lexical environment; recursion via defun
 *
 * This is an interpreter, NOT SBCL (no native codegen). It is a genuine working
 * Common-Lisp-subset runtime: it evaluates real Lisp programs (recursion,
 * higher-order via lambda, list building, arithmetic).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

typedef enum { T_INT, T_SYM, T_CONS, T_NIL, T_PRIM, T_CLOSURE, T_TRUE } Tag;

struct Obj;
typedef struct Obj Obj;
typedef Obj *(*PrimFn)(Obj *args);

struct Obj {
  Tag tag;
  long ival;          /* T_INT */
  char *sym;          /* T_SYM */
  Obj *car, *cdr;     /* T_CONS */
  PrimFn prim;        /* T_PRIM */
  Obj *params, *body, *env; /* T_CLOSURE */
};

static Obj *NIL, *TRUE;

static Obj *alloc(Tag t) {
  Obj *o = calloc(1, sizeof(Obj));
  o->tag = t;
  return o;
}
static Obj *mkint(long v) { Obj *o = alloc(T_INT); o->ival = v; return o; }
static Obj *cons(Obj *a, Obj *d) { Obj *o = alloc(T_CONS); o->car = a; o->cdr = d; return o; }

/* symbol interning */
#define MAXSYM 4096
static char *symtab[MAXSYM]; static Obj *symobj[MAXSYM]; static int nsym = 0;
static Obj *intern(const char *s) {
  for (int i = 0; i < nsym; i++) if (!strcmp(symtab[i], s)) return symobj[i];
  Obj *o = alloc(T_SYM); o->sym = strdup(s);
  symtab[nsym] = o->sym; symobj[nsym] = o; nsym++;
  return o;
}

/* ---- reader ---- */
static const char *src;
static void skipws(void) {
  for (;;) {
    while (*src && isspace((unsigned char)*src)) src++;
    if (*src == ';') { while (*src && *src != '\n') src++; }
    else break;
  }
}
static Obj *read_expr(void);
static Obj *read_list(void) {
  skipws();
  if (*src == ')') { src++; return NIL; }
  if (*src == 0) { fprintf(stderr, "unexpected EOF in list\n"); exit(1); }
  Obj *head = read_expr();
  Obj *rest = read_list();
  return cons(head, rest);
}
static Obj *read_expr(void) {
  skipws();
  if (*src == 0) return NULL;
  if (*src == '(') { src++; return read_list(); }
  if (*src == '\'') { src++; return cons(intern("quote"), cons(read_expr(), NIL)); }
  /* atom */
  const char *start = src;
  while (*src && !isspace((unsigned char)*src) && *src != '(' && *src != ')' && *src != '\'') src++;
  int len = (int)(src - start);
  char buf[256];
  if (len >= (int)sizeof(buf)) len = sizeof(buf) - 1;
  memcpy(buf, start, len); buf[len] = 0;
  /* integer? */
  char *end; long v = strtol(buf, &end, 10);
  if (*end == 0 && end != buf) return mkint(v);
  if (!strcmp(buf, "nil")) return NIL;
  if (!strcmp(buf, "t")) return TRUE;
  return intern(buf);
}

/* ---- environment: list of (sym . val) frames; env is a list of frames ---- */
static Obj *env_extend(Obj *params, Obj *args, Obj *parent) {
  Obj *frame = NIL;
  while (params->tag == T_CONS) {
    Obj *p = params->car;
    Obj *a = (args->tag == T_CONS) ? args->car : NIL;
    frame = cons(cons(p, a), frame);
    params = params->cdr;
    if (args->tag == T_CONS) args = args->cdr;
  }
  return cons(frame, parent); /* env = (frame . parent-env) */
}
static Obj **env_find(Obj *env, Obj *sym) {
  while (env->tag == T_CONS) {
    Obj *frame = env->car;
    while (frame->tag == T_CONS) {
      if (frame->car->car == sym) return &frame->car->cdr;
      frame = frame->cdr;
    }
    env = env->cdr;
  }
  return NULL;
}

/* global env */
static Obj *genv;
static void def_global(Obj *sym, Obj *val) {
  Obj **slot = env_find(genv, sym);
  if (slot) { *slot = val; return; }
  /* prepend into the global frame */
  genv->car = cons(cons(sym, val), genv->car);
}

static Obj *eval(Obj *e, Obj *env);
static Obj *eval_list(Obj *e, Obj *env) {
  if (e->tag != T_CONS) return NIL;
  return cons(eval(e->car, env), eval_list(e->cdr, env));
}

static int truthy(Obj *o) { return o != NIL; }

static Obj *apply(Obj *fn, Obj *args) {
  if (fn->tag == T_PRIM) return fn->prim(args);
  if (fn->tag == T_CLOSURE) {
    Obj *env = env_extend(fn->params, args, fn->env);
    Obj *r = NIL; Obj *b = fn->body;
    while (b->tag == T_CONS) { r = eval(b->car, env); b = b->cdr; }
    return r;
  }
  fprintf(stderr, "not a function\n"); exit(1);
}

static Obj *eval(Obj *e, Obj *env) {
  if (e->tag == T_INT || e->tag == T_NIL || e->tag == T_TRUE || e->tag == T_PRIM) return e;
  if (e->tag == T_SYM) {
    Obj **slot = env_find(env, e);
    if (slot) return *slot;
    fprintf(stderr, "unbound symbol: %s\n", e->sym); exit(1);
  }
  /* list -> special form or application */
  Obj *head = e->car;
  if (head->tag == T_SYM) {
    const char *s = head->sym;
    if (!strcmp(s, "quote")) return e->cdr->car;
    if (!strcmp(s, "if")) {
      Obj *c = eval(e->cdr->car, env);
      if (truthy(c)) return eval(e->cdr->cdr->car, env);
      Obj *els = e->cdr->cdr->cdr;
      return (els->tag == T_CONS) ? eval(els->car, env) : NIL;
    }
    if (!strcmp(s, "cond")) {
      Obj *cl = e->cdr;
      while (cl->tag == T_CONS) {
        Obj *clause = cl->car;
        Obj *test = clause->car;
        if ((test->tag == T_SYM && !strcmp(test->sym, "t")) || truthy(eval(test, env))) {
          Obj *r = NIL; Obj *b = clause->cdr;
          while (b->tag == T_CONS) { r = eval(b->car, env); b = b->cdr; }
          return r;
        }
        cl = cl->cdr;
      }
      return NIL;
    }
    if (!strcmp(s, "lambda")) {
      Obj *o = alloc(T_CLOSURE); o->params = e->cdr->car; o->body = e->cdr->cdr; o->env = env;
      return o;
    }
    if (!strcmp(s, "defun")) {
      Obj *name = e->cdr->car;
      Obj *o = alloc(T_CLOSURE); o->params = e->cdr->cdr->car; o->body = e->cdr->cdr->cdr; o->env = genv;
      def_global(name, o);
      return name;
    }
    if (!strcmp(s, "define")) {
      Obj *name = e->cdr->car;
      Obj *v = eval(e->cdr->cdr->car, env);
      def_global(name, v);
      return v;
    }
    if (!strcmp(s, "setq")) {
      Obj *name = e->cdr->car;
      Obj *v = eval(e->cdr->cdr->car, env);
      Obj **slot = env_find(env, name);
      if (slot) *slot = v; else def_global(name, v);
      return v;
    }
    if (!strcmp(s, "let")) {
      Obj *binds = e->cdr->car;
      Obj *frame = NIL;
      while (binds->tag == T_CONS) {
        Obj *b = binds->car;
        Obj *val = eval(b->cdr->car, env);
        frame = cons(cons(b->car, val), frame);
        binds = binds->cdr;
      }
      Obj *nenv = cons(frame, env);
      Obj *r = NIL; Obj *body = e->cdr->cdr;
      while (body->tag == T_CONS) { r = eval(body->car, nenv); body = body->cdr; }
      return r;
    }
    if (!strcmp(s, "progn")) {
      Obj *r = NIL; Obj *b = e->cdr;
      while (b->tag == T_CONS) { r = eval(b->car, env); b = b->cdr; }
      return r;
    }
  }
  /* application */
  Obj *fn = eval(head, env);
  Obj *args = eval_list(e->cdr, env);
  return apply(fn, args);
}

/* ---- primitives ---- */
static long need_int(Obj *o) { if (o->tag != T_INT) { fprintf(stderr, "expected int\n"); exit(1);} return o->ival; }
static Obj *p_add(Obj *a){ long s=0; while(a->tag==T_CONS){s+=need_int(a->car);a=a->cdr;} return mkint(s);}
static Obj *p_sub(Obj *a){ if(a->tag!=T_CONS) return mkint(0); long s=need_int(a->car); a=a->cdr; if(a->tag!=T_CONS) return mkint(-s); while(a->tag==T_CONS){s-=need_int(a->car);a=a->cdr;} return mkint(s);}
static Obj *p_mul(Obj *a){ long s=1; while(a->tag==T_CONS){s*=need_int(a->car);a=a->cdr;} return mkint(s);}
static Obj *p_eq_num(Obj *a){ long x=need_int(a->car); a=a->cdr; while(a->tag==T_CONS){ if(need_int(a->car)!=x) return NIL; a=a->cdr;} return TRUE;}
static Obj *p_lt(Obj *a){ long x=need_int(a->car); long y=need_int(a->cdr->car); return x<y?TRUE:NIL;}
static Obj *p_gt(Obj *a){ long x=need_int(a->car); long y=need_int(a->cdr->car); return x>y?TRUE:NIL;}
static Obj *p_cons(Obj *a){ return cons(a->car, a->cdr->car);}
static Obj *p_car(Obj *a){ Obj *x=a->car; return x->tag==T_CONS?x->car:NIL;}
static Obj *p_cdr(Obj *a){ Obj *x=a->car; return x->tag==T_CONS?x->cdr:NIL;}
static Obj *p_atom(Obj *a){ return a->car->tag==T_CONS?NIL:TRUE;}
static Obj *p_null(Obj *a){ return a->car==NIL?TRUE:NIL;}
static Obj *p_not(Obj *a){ return a->car==NIL?TRUE:NIL;}
static Obj *p_eq(Obj *a){ Obj*x=a->car,*y=a->cdr->car; if(x==y) return TRUE; if(x->tag==T_INT&&y->tag==T_INT&&x->ival==y->ival) return TRUE; return NIL;}
static Obj *p_list(Obj *a){ return a; } /* args already an evaluated list */

static void reg(const char *n, PrimFn f) { Obj *o = alloc(T_PRIM); o->prim = f; def_global(intern(n), o); }

/* ---- printer ---- */
static void print_obj(Obj *o) {
  switch (o->tag) {
    case T_INT: printf("%ld", o->ival); break;
    case T_NIL: printf("nil"); break;
    case T_TRUE: printf("t"); break;
    case T_SYM: printf("%s", o->sym); break;
    case T_CLOSURE: printf("#<closure>"); break;
    case T_PRIM: printf("#<prim>"); break;
    case T_CONS: {
      printf("(");
      Obj *p = o;
      int first = 1;
      while (p->tag == T_CONS) { if (!first) printf(" "); first = 0; print_obj(p->car); p = p->cdr; }
      if (p != NIL) { printf(" . "); print_obj(p); }
      printf(")");
      break;
    }
  }
}

int main(void) {
  NIL = alloc(T_NIL); TRUE = alloc(T_TRUE);
  genv = cons(NIL, NIL); /* one global frame */
  reg("+", p_add); reg("-", p_sub); reg("*", p_mul); reg("=", p_eq_num);
  reg("<", p_lt); reg(">", p_gt); reg("cons", p_cons); reg("car", p_car);
  reg("cdr", p_cdr); reg("atom", p_atom); reg("null", p_null); reg("not", p_not);
  reg("eq", p_eq); reg("list", p_list);

  /* slurp stdin */
  static char buf[1 << 20];
  size_t n = fread(buf, 1, sizeof(buf) - 1, stdin);
  buf[n] = 0;
  src = buf;

  Obj *last = NIL;
  for (;;) {
    skipws();
    if (*src == 0) break;
    Obj *e = read_expr();
    if (!e) break;
    last = eval(e, genv);
  }
  print_obj(last);
  printf("\n");
  return 0;
}

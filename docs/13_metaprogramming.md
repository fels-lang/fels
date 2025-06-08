# Metaprogramming: Macros, Quote/Insert, and Code Generation

> Status: **IMPLEMENTED.** Template macros substitute splices through *every*
> statement and expression form (`match`, `for`, compound literals, `defer`,
> `zone`, `unsafe`, type position, …), are hygienic, and support `#for`
> unrolling and `#parse`. For computed (loop/logic-driven) code generation, use
> the programmatic path (`#insert #run gen()` + first-class `ast.*` values, and
> `#compiler` hooks) described at the end and in
> [09](09_comptime_vm_roadmap.md) / [12](12_reflection_and_constraints.md).

K2 has two complementary ways to generate code at compile time:

1. **Template macros** — a syntactic, hygienic substitution engine. Best for
   "stamp out this shape with these holes filled in." Covered first.
2. **Programmatic generation** — run real K2 in the comptime VM, build an AST as a
   first-class value, and splice it. Best when the code's *structure* depends on
   logic (loops over fields, conditionals on types). Covered last.

---

## 1. Quote and insert

`#quote { ... }` captures a block of code as a typed AST value rather than
running it. `#insert <code>;` splices an AST value back into the program at that
point, where it is then type-checked normally.

```k2
#entry
main :: fn() -> i32 {
    #insert #quote { x := 40; };  // splices `x := 40;` here
    return x + 2;                 // 42
}
```

A bare `#insert #quote { ... }` is **not** hygienic — the locals it introduces
(`x` above) leak into the surrounding scope on purpose, so you can use them. (A
*macro*'s locals do not leak; see [Hygiene](#4-hygiene).)

`#quote(expr)` is the expression form: it captures a single expression as an
`AstExpr` value.

---

## 2. Macros

A macro is a compile-time template. It is declared like a function but with the
`macro` keyword, and its body must be a single `return #quote { ... };`:

```k2
swap :: macro(a: Expr, b: Expr) {
    return #quote {
        t := $a;
        $a = $b;
        $b = t;
    };
}

#entry
main :: fn() -> i32 {
    x: i32 = 7; y: i32 = 49;
    #insert swap(x, y);   // now x = 49, y = 7
    return x - y;         // 49 - 7 = 42
}
```

Inside the template, **`$name` is a *splice hole*** that is replaced by the
argument bound to the macro parameter `name`. A macro is expanded at each
`#insert` site *before* type-checking, so the result is checked as if you had
written it by hand.

### Parameter types

A macro parameter's type constrains what kind of argument it accepts:

| Parameter type | Accepts | Use |
|---|---|---|
| `Expr` / `AstExpr` | an expression (not a `#quote` block) | `$p` in expression or type position |
| `Block` / `AstBlock` | a `#quote { ... }` block | `$p;` to inline the block's statements |
| `Code` (or untyped) | anything | flexible |

A mismatched argument is rejected with a clear error (e.g. *"parameter `body`
expects a `#quote { ... }` block"*).

### Block splice

A `Block`/`AstBlock` parameter is spliced as a **statement** with `$body;`, which
inlines that block's statements verbatim:

```k2
twice :: macro(body: Block) {
    return #quote { $body; $body; };
}

#entry
main :: fn() -> i32 {
    n: i32 = 0;
    #insert twice(#quote { n = n + 21; });  // runs the block twice
    return n;                                 // 42
}
```

### Splices work everywhere

Splice holes are substituted through **all** statement and expression forms,
including inside `match` arms, runtime `for`/`while` bodies, compound literals,
`defer`, `zone`, `unsafe`, `catch`, slices — and in **type position**:

```k2
Pair :: struct { a: i32, b: i32 }

build :: macro(out: Expr, ty: Expr, sel: Expr, lo: Expr, hi: Expr) {
    return #quote {
        p: Pair = .{ $lo, $hi };               // splice inside `.{ }`
        acc: $ty = 0;                          // type-position splice
        for k in p.a..p.b { acc = acc + k; }   // runtime for body
        match $sel {                           // splice as the match subject
            1 => { $out = acc + p.a; }
            else => { $out = acc; }
        }
    };
}
```

---

## 3. `#for` — compile-time unrolling

`#for i in a..b { ... }` inside a template is **unrolled** at expansion time: the
body is emitted once per index, with the loop variable available as a *comptime
value* spliced with `$(i)`:

```k2
sum_first :: macro(out: Expr) {
    return #quote {
        #for i in 0..4 { $out = $out + $(i); }  // → out = out+0; out+1; out+2; out+3;
    };
}
```

Note the distinction:

- A **runtime** loop `for k in 0..n { ... k ... }` keeps `k` as an ordinary
  runtime variable, referenced bare (`k`).
- A **comptime** `#for i in 0..4 { ... $(i) ... }` is unrolled; `i` is a comptime
  literal, spliced with `$(i)`. The bounds must be integer literals (or macro
  parameters bound to literals).

---

## 4. Hygiene

A macro's own locals are **renamed to fresh, collision-free names** so they can
never capture — or be captured by — names in the caller. This includes locals,
`for`/`while` loop variables, and `match`/`if` capture bindings:

```k2
accumulate :: macro(out: Expr, n: Expr) {
    return #quote {
        tmp := 0;
        for k in 0..$n { tmp = tmp + k; }
        $out = tmp;
    };
}

#entry
main :: fn() -> i32 {
    tmp: i32 = 100;   // untouched — the macro's `tmp` is a different variable
    k: i32 = 7;       // untouched — the macro's `k` is a different variable
    r: i32 = 0;
    #insert accumulate(r, 9);          // 0+1+…+8 = 36 → r
    return r + (tmp - 100) + (k - 7);  // 36 (proves no capture)
}
```

To deliberately produce a binding the caller can name, write to a variable the
caller passes in (an `Expr` parameter, like `$out` above), or use a bare
`#insert #quote { ... }`, whose locals are *not* hygienic.

---

## 5. `#parse` — the string escape hatch

`#parse(string_expr)` evaluates a string at compile time, parses it as code, and
(as an `#insert` operand) splices it. This is the untyped escape hatch out of
quotations — useful when the code is assembled as text:

```k2
#insert #parse("answer := 42;");
```

Prefer typed `#quote`/macros where possible; reach for `#parse` only when you
genuinely have code as a string.

---

## 6. Errors and gotchas

- A `$name` splice **only** means something inside a macro template's
  `return #quote { ... }`, and `name` must be one of the macro's parameters.
  A stray `$` elsewhere is an error.
- The macro body must be exactly one `return #quote { ... };` — a macro is a
  *template*, not a place to run logic. For logic-driven generation, use the
  programmatic path below.
- A `Block` argument cannot be spliced in expression position (`$b` where an
  expression is expected) — splice it as a statement (`$b;`) instead.

---

## 7. Programmatic generation (when templates aren't enough)

When the *shape* of the generated code depends on compile-time logic — iterating
over a type's fields, branching on `type_info(T)`, accumulating a list of
statements — build the AST as a first-class value and splice the result:

```k2
gen :: fn() -> AstBlock { /* build statements with ast.* constructors */ }

#entry
main :: fn() -> i32 {
    #insert #run gen();   // runs gen() in the comptime VM, splices its AST
    return answer;
}
```

The comptime VM exposes the AST as matchable `ast.*` values (see
[09](09_comptime_vm_roadmap.md)). This path can construct *any* form (full
control flow, compound literals, declarations) and underpins reflection-driven
code generation and `#compiler` hooks. Reflection helpers that pair well with it
(`type_info`, `typeid_of`, `Any`, field navigation) are documented in
[12](12_reflection_and_constraints.md).

## 8. `#derive` — generated impls from a type's shape

Tag a struct with `#derive(...)` and the compiler writes the mechanical, field-by-
field implementation for you — no per-type boilerplate:

```k2
#derive(Eq)
Vec3 :: struct { x: i32, y: i32, z: i32 }

a: Vec3 = .{ 1, 2, 3 };
b: Vec3 = .{ 1, 2, 3 };
if a.eq(&b) { ... }     // `eq` was generated; called via UFCS
```

`#derive(Eq)` synthesizes `eq(self: *Self, other: *Self) -> bool` as an in-struct
method (`return self.x == other.x && self.y == other.y && …`; an empty struct is
always equal). It works on multi-field, **generic** (`Box($T)`), and empty structs,
and a method is generated per instantiation. List several to derive at once:
`#derive(Eq, Hash)`.

Unlike Rust's `#[derive]` (proc-macros with full ambient power — the `build.rs`
supply-chain surface), a k2 derive is a compiler-side generator driven by the type's
structure; the roadmap (R2, [09](09_comptime_vm_roadmap.md)) scopes user-written
generators to a pure `AstTransform` capability so a third-party derive **cannot**
touch the filesystem, network, or FFI. *Derive without the build.rs risk.*

> Built-in derives so far: `Eq`. `Hash`, `format`, and `json` follow the same shape
> (walk the fields, emit the impl) — they slot into the derive registry in
> `src/parser.zig:synthDerive`.

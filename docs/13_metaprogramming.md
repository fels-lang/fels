# Metaprogramming: Macros, Quote/Insert, and Code Generation

Fels gives you two ways to generate code at compile time.

Template macros are a syntactic, hygienic substitution engine. A macro stamps out a shape with
its holes filled in. Programmatic generation runs real Fels in the comptime VM, builds an AST as
a first-class value and splices it into the program. Reach for it when the structure of the code
depends on logic, such as a loop over fields or a branch on a type. This page covers macros
first and the programmatic path at the end.

## 1. Quote and insert

`#quote { ... }` captures a block of code as a typed AST value instead of running it.
`#insert <code>;` splices an AST value back into the program at that point, and from there it is
type-checked like any other code.

```fels
#entry
main :: fn() -> i32 {
    #insert #quote { x := 40; };  // splices `x := 40;` here
    return x + 2;                 // 42
}
```

A bare `#insert #quote { ... }` is **not** hygienic. The locals it introduces (`x` above) leak
into the surrounding scope on purpose, so they are yours to use afterwards. (A *macro*'s locals
do not leak, see [Hygiene](#4-hygiene).)

`#quote(expr)` is the expression form. It captures a single expression as an `AstExpr` value.

## 2. Macros

A macro is a compile-time template. You declare it like a function, with `macro` in place of
`fn`, and its body must be a single `return #quote { ... };`. `macro` is not a reserved word. It
only has this meaning after `::`, so you can still use it as an ordinary name. Macros are top
level declarations, and a struct body holds only fields and `fn` methods.

```fels
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

Inside the template, **`$name` is a *splice hole***. It is replaced by the argument bound to the
macro parameter `name`. A macro is expanded at each `#insert` site *before* type-checking, so
the result is checked as if you had written it by hand.

### Parameter types

The type of a macro parameter decides what kind of argument it accepts:

| Parameter type | Accepts | Use |
|---|---|---|
| `Expr` / `AstExpr` | an expression (not a `#quote` block) | `$p` in expression or type position |
| `Block` / `AstBlock` | a `#quote { ... }` block | `$p;` to inline the block's statements |
| `Code` (or untyped) | anything | flexible |

An argument of the wrong kind is rejected with a clear error, for example *"parameter `body`
expects a `#quote { ... }` block"*.

### Block splice

You splice a `Block`/`AstBlock` parameter as a **statement** with `$body;`, and that inlines the
block's statements verbatim:

```fels
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

Splice holes are substituted through **all** statement and expression forms. That includes
`match` arms, runtime `for`/`while` bodies, compound literals, `defer`, `zone`, `unsafe`,
`catch` and slices, and it includes **type position** too:

```fels
Pair :: struct { a: i32, b: i32 }

build :: macro(out: Expr, ty: Expr, sel: Expr, lo: Expr, hi: Expr) {
    return #quote {
        p: Pair = .{ $lo, $hi };               // splice inside `.{ }`
        acc: $ty = 0;                          // type-position splice
        for k in p.a..p.b { acc = acc + k; }   // runtime for body
        match $sel {                           // splice as the match subject
            1 => { $out = acc + p.a; },
            else => { $out = acc; },
        }
    };
}
```

## 3. `#for` — compile-time unrolling

Inside a template, `#for i in a..b { ... }` is **unrolled** at expansion time. The body is
emitted once per index, and the loop variable is available as a *comptime value* that you
splice with `$(i)`:

```fels
sum_first :: macro(out: Expr) {
    return #quote {
        #for i in 0..4 { $out = $out + $(i); }  // → out = out+0; out+1; out+2; out+3;
    };
}
```

The two loops look alike, but they work differently:

- A **runtime** loop `for k in 0..n { ... k ... }` keeps `k` as an ordinary runtime variable,
  and you refer to it bare (`k`).
- A **comptime** `#for i in 0..4 { ... $(i) ... }` is unrolled. Here `i` is a comptime literal,
  and you splice it with `$(i)`. The bounds must be integer literals (or macro parameters bound
  to literals).

## 4. Hygiene

A macro's own locals are **renamed to fresh, collision-free names**. That way they can never
capture a name in the caller, and no name in the caller can capture them. This covers locals,
`for`/`while` loop variables and `match`/`if` capture bindings:

```fels
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

When you want a binding the caller can name, write to a variable the caller passes in (an
`Expr` parameter, like `$out` above). Or use a bare `#insert #quote { ... }`, whose locals are
*not* hygienic.

## 5. `#parse` — the string escape hatch

`#parse(string_expr)` evaluates a string at compile time and parses it as code. As an `#insert`
operand, it splices that code into the program. This is the untyped escape hatch out of
quotations, and it is useful when you assemble the code as text:

```fels
#insert #parse("answer := 42;");
```

Prefer typed `#quote` and macros where you can. Reach for `#parse` only when you really have
the code as a string.

## 6. Errors and gotchas

- A `$name` splice **only** means something inside a macro template's `return #quote { ... }`,
  and `name` must be one of the macro's parameters. A stray `$` elsewhere is an error.
- The macro body must be exactly one `return #quote { ... };`. A macro is a *template*, not a
  place to run logic. For generation that is driven by logic, use the programmatic path below.
- A `Block` argument cannot be spliced in expression position (`$b` where an expression is
  expected). Splice it as a statement (`$b;`) instead.

## 7. Programmatic generation (when templates aren't enough)

Sometimes the *shape* of the generated code depends on compile-time logic. You might iterate
over a type's fields, branch on `core::type_info(T)` or accumulate a list of statements. Then
you build the AST as a first-class value and splice the result:

```fels
gen :: fn() -> AstBlock {
    // Any compile-time logic can choose or assemble the statements here
    // (with `#quote` pieces or the `ast.*` constructors).
    return #quote { answer := 42; };
}

#entry
main :: fn() -> i32 {
    #insert #run gen();   // runs gen() in the comptime VM, splices its AST
    return answer;
}
```

The comptime VM exposes the AST as `ast.*` values that you can match on (see
[09](09_comptime.md)). This path can construct *any* form, including full control flow,
compound literals and declarations. Reflection-driven code generation and `#compiler` hooks are
built on it. The reflection helpers that pair well with it (`core::type_info`, `core::type_id`,
`Any`, field navigation) are documented in [12](12_reflection_and_constraints.md).

## 8. `#derive` — generated impls from a type's shape

Tag a struct with `#derive(...)` and the compiler writes the mechanical, field-by-field
implementation for you, so there is no boilerplate to write for each type:

```fels
#derive(Eq)
Vec3 :: struct { x: i32, y: i32, z: i32 }

a: Vec3 = .{ 1, 2, 3 };
b: Vec3 = .{ 1, 2, 3 };
if a.eq(&b) { ... }     // `eq` was generated; called via UFCS
```

Each generator builds an in-struct method (or an associated function) from the struct's
fields. These generators are built in:

| Derive | Generates | Call |
|---|---|---|
| `Eq` | `eq(self, other) -> bool`, field-by-field `&&` | `a.eq(&b)` |
| `Ord` | `cmp(self, other) -> i32`, lexicographic `-1/0/1` | `a.cmp(&b)` |
| `Hash` | `hash(self) -> u64`, an FNV-1a-style mix of the fields | `a.hash()` |
| `Default` | `default() -> Self`, `.{}` (associated fn) | `T::default()` |
| `Clone` | `clone(self) -> Self`, a structural copy | `a.clone()` |
| `Add`/`Sub`/`Mul` | `add`/`sub`/`mul(self, other) -> Self`, field-wise | `a.add(&b)` |
| `Neg` | `neg(self) -> Self`, field-wise negation | `a.neg()` |
| `Min`/`Max` | field-wise via `core::min`/`core::max` | `a.min(&b)` |
| `Clamp` | field-wise `core::clamp(self.f, lo.f, hi.f)` | `a.clamp(&lo, &hi)` |
| `Scale` | `scale(self, s) -> Self`, multiplies each field by scalar `s` | `a.scale(2)` |
| `Lerp` | `lerp(self, other, t) -> Self`, field-wise interpolation | `a.lerp(&b, t)` |
| `format` | `format(self, sb)` → `"Vec2 { x: 3, y: 4 }"` into a `StringBuilder` | `a.format(&sb)` |

You can list several at once: `#derive(Eq, Ord, Hash, Add, Lerp, format)`. They work on
multi-field structs, on **generic** ones (`Box($T)`, with a method per instantiation) and on
empty structs. The generated bodies apply operators like `==`, `<` and `+` to the struct's own
fields, so a field whose type doesn't support the operation gives a clear compile error.

Fels has no operator overloading, so the arithmetic and vector derives
(`Add`/`Sub`/`Mul`/`Neg`/`Min`/`Max`/`Clamp`/`Scale`/`Lerp`) are how you do vector math. They
are ideal for `std.math`'s `Vec2`/`Vec3`/`Color`. `format` needs the struct's file to bring
`StringBuilder` into scope (`#import std.strings.{StringBuilder};`). It dispatches per field
type (`append_i64`/`append_u64`/`append_f64`/`append_bool`) and recurses into a nested type's
own `format`. `Eq` recurses as well: a field whose type is another named type is compared with
that type's own `eq`, so that type must derive `Eq` too. `Default` and `Clone` accept nested
fields, because they build `.{}` or copy each field as it is. The other derives apply their
operator to the nested value directly, so a field of struct type does not compile with them.

### Writing your own derive

The built-ins above are not special, because `#derive` is **open**. When the compiler doesn't
recognize a `#derive(Name)`, that is *not an error*. The derive stays on the declaration, and a
`#compiler` hook can handle it. `core::compiler_decls()` exposes the derives each declaration
asks for as `Decl.derives` (the space-separated `#derive(...)` names). A hook filters for the
structs that opted in and generates their impl:

```fels
#import std.heap as heap;
#import std.strings as str;

#compiler
derive_sum :: fn() -> []const u8 {
    a := heap::make();
    sb := str::builder(&a);
    for d in core::compiler_decls() {
        match d.derives {                       // a string match (`d.derives == "Sum"` works too)
            "Sum" => {
                sb.append("sum_"); sb.append(d.name);
                sb.append(" :: fn(p: "); sb.append(d.name); sb.append(") -> i32 { return 0");
                for f in d.fields { sb.append(" + p."); sb.append(f.name); }
                sb.append("; } ");
            },
            else => {},
        }
    }
    return sb.str();
}

#derive(Sum)
Point :: struct { x: i32, y: i32 }              // → `sum_Point` is generated
```

Built-in (parser-side) and user (hook-side) derives can sit on the same struct. For a struct
with several derives, `Decl.derives` is `"A B C"`. So match the exact string when you look for a
single derive, or check for a substring to test membership.

A Fels derive is a compiler-side generator driven by the structure of the type. It is not a
proc-macro with ambient power. The plan is to scope user-written generators to a pure
`AstTransform` capability ([09](09_comptime.md)), so that a third-party derive can't reach the
filesystem, the network or FFI.

> Built-in derives: `Eq`, `Ord`, `Hash`, `Default`, `Clone`, `Add`, `Sub`, `Mul`,
> `Neg`, `Min`, `Max`, `Clamp`, `Scale`, `Lerp`, `format`. Derives such as `json`,
> `Builder` or `bytes` are ideas only and are not implemented. A new built-in derive would be
> one more case in `src/parser.zig:synthDerive`, and a `#compiler` hook can provide one today.

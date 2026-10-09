# Reflection, Any, and constraints


Reflection in Fels works at comptime and at runtime, and it threads through generics.

At comptime, `core::type_info(T)` is a matchable value, so you can `match` on a type's structure:
its struct fields, enum variants or scalar kind. Constraints build on it. There are built-in
predicates (`$T: Numeric`/`Int`/`Float`/`Struct`/`Enum`/`Ptr`/…), named
`Name :: constraint($T) { … }` declarations, and `where { … }` blocks that inspect
`core::type_info(T)` and can `core::reject("msg")`. The predicate runs during generic resolution,
so a bad type fails at the call site before the body is checked. A `where` can also compute an
output type param (`-> $Acc`).

At runtime, `core::type_id(T)` is a stable type identity. It is a content hash and is comparable
across compilation units. `core::type_name(T)` and `core::sizeof(T)` fold to real runtime values;
`type_name` spells the type as it is written (`[]i32`, `*Point`, `?i32`, `[4]u8`, `Pair(i32)`).
Each of these takes a value too: `core::type_name(x)` is the name of `x`'s type. A type of the
same name wins over a variable.
`Any` is a type-erased value: `any(x)` wraps a value, and `any_as(v, T) -> ?T` is a safe
downcast. The metadata travels inline with the value, baked as a tree-shaken string literal, so
reflection you don't use costs nothing. With the free functions `any_field_at`, `any_elem` and
`any_deref`, a generic walker recurses through struct fields, slice elements and pointers. That
is enough for reflection-driven serialization with no per-type code, which `std.serde` does.

> In code, these builtins carry their `core::` prefix: `core::type_info(T)`,
> `core::type_id(T)`, `core::type_name(T)`, `core::sizeof(T)`, `core::any(x)`,
> `core::reject(msg)` and `core::require(T, C)`. A bare name is a compile error (see
> [08](08_attributes_builtins.md)). The design text below often leaves the prefix out.

## Design thesis

**The comptime VM executes the same IR as the runtime backend.** Comptime and runtime
therefore behave the same, and an `#run` FNV-1a hash equals its runtime value bit for bit. That
lets *one* reflection surface serve both phases.

The design rests on five orthogonal primitives. Each is type-safe, and each composes with the
rest:

1. **`TypeInfo`**: a matchable tagged enum that describes a type. It is the same value at
   comptime and runtime.
2. **`typeid`**: a cheap, stable runtime identity for a type (a content hash, not a pointer).
3. **`Any`**: a `(pointer, typeid)` pair with *safe* navigation and downcasting.
4. **`constraint`**: a comptime predicate over `TypeInfo`. `$T: C` and interface conformance
   are the same mechanism.
5. **`where`**: either a per-instantiation block that can inspect, *rewrite* and *reject* the
   type bindings (overload fallback is planned), **or** interface bounds. In the second form,
   `fn($T, x: *T) where T: Show` is equivalent to the inline `fn($T: Show, …)`, and you
   comma-separate several bounds (`where T: A, U: B`). A bound type is checked for conformance,
   and the interface's methods are callable on it directly (`x.val()`), not only via a
   `*Iface` value.

Reflection-driven serialization, custom iteration and code generation all fall out of these,
with no new directives.

## 1. `TypeInfo`: reflection as a matchable value

`core::type_info(T)` returns a real tagged enum, not a set of ad-hoc fields. It has the same
shape as the `ast.*` metaprogramming surface, and the compiler injects it as a prelude when a
module uses reflection.

> **Implemented today:** `core::type_info(T)` returns such an enum. Its variants are
> `void_`, `boolean`, `int`, `float`, `pointer`, `slice`, `array`, `optional`, `struct_`,
> `union_`, `enum_` and `other` (the name of any other type). The payloads are, as built:
>
> ```fels
> TiInt     :: struct { bits: u16, signed: bool }
> TiFloat   :: struct { bits: u16 }
> TiPtr     :: struct { elem: *TypeInfo, is_const: bool }
> TiArray   :: struct { len: usize, elem: *TypeInfo }
> TiField   :: struct { name: []const u8, ty: *TypeInfo, offset: usize, bit: u32, bits: u16 }
> TiStruct  :: struct { name: []const u8, fields: []TiField, id: usize, size: usize, bit_packed: bool }
> TiVariant :: struct { name: []const u8, has_payload: bool, value: i64 }
> TiEnum    :: struct { name: []const u8, variants: []TiVariant }
> ```
>
> A field's `offset` is its byte offset; in a `#packed` struct `bit` and `bits` place an integer
> field. A union is `union_` with a `TiStruct` whose fields all start at 0. A variant's `value`
> is its tag. An error set is an `enum_` of its own errors, each `value` the error's number, and
> the type `error` lists every error of the program. Function, interface and distinct types are
> `other` today: the `fn_`, `iface` and `distinct_` variants below, a variant's payload type, a
> field's `is_const` and a struct's `align` are still design. (`void`, `bool` and `distinct` are
> keywords, so those variants are spelled `void_`, `boolean` and `distinct_`.)

```fels
TypeInfo :: enum {
    void_,
    boolean,
    int:      IntInfo,        // { bits: u16, signed: bool }
    float:    FloatInfo,      // { bits: u16 }
    pointer:  PtrInfo,        // { elem: *TypeInfo, is_const: bool }
    slice:    *TypeInfo,
    array:    ArrayInfo,      // { len: usize, elem: *TypeInfo }
    optional: *TypeInfo,
    fn_:      FnInfo,         // { params: []*TypeInfo, ret: *TypeInfo, is_extern: bool }
    struct_:  StructInfo,     // { name, fields: []FieldInfo, size, align }
    enum_:    EnumInfo,       // { name, variants: []VariantInfo, tag_bits }
    iface:    IfaceInfo,      // { name, methods: []MethodInfo }
    distinct_: DistinctInfo,  // { name, underlying: *TypeInfo }
}

FieldInfo   :: struct { name: []const u8, ty: *TypeInfo, offset: usize, is_const: bool }
VariantInfo :: struct { name: []const u8, payload: ?*TypeInfo, tag: u32 }
```

`core::type_info(T) -> TypeInfo` folds at comptime *and* is available at runtime (see §4).
Because it's a tagged enum, you inspect it with `match`, not by casting:

```fels
describe :: fn(info: TypeInfo) -> []const u8 {
    match info {
        .int |i|     => { return if i.signed { "signed integer" } else { "unsigned integer" }; },
        .struct_ |s| => { return s.name; },
        .slice |elem| => { return "slice"; },
        else         => { return "other"; },
    }
}
```

> **Why a match.** `match info { .int |i| => … }` binds the payload, so there is no cast to
> get wrong, and the compiler checks that you handled every kind or wrote an `else`.

## 2. `typeid`: cheap runtime identity

> **Implemented today:** `core::type_id(T) -> usize`, a stable runtime id for a type. It folds
> at IR lowering to an **FNV-1a content hash** of the type's canonical spelling. Identical types
> therefore always share an id, and distinct types differ, including `*i32` vs `i32`, `[]i32` vs
> `i32` and two structurally-identical structs. The id is also **stable across compilation
> units**, because there is no global numbering. In a generic, `core::type_id(T)` folds per
> instantiation. Identity tests are a single `usize` compare. When a program uses `Any`, the
> compiler also generates `type_name_of(id)` and `type_size_of(id)`, which give a type's name and
> size from a bare id. They know the scalar types, the program's structs and their field types,
> and they return `"?"` or 0 for any other id. The
> full lookup `info_of(id)`, which would return a `TypeInfo`, is still design and needs §4.
> `core::typeid_of(T)` is an older spelling of the same builtin, and these docs use
> `core::type_id(T)`.

```fels
core::type_id(T) -> usize        // a stable id (content hash); IMPLEMENTED
core::type_id(any_value) -> usize   // value form: design (needs Any)
info_of(id) -> *TypeInfo        // table lookup: design (§4)
```

Two identical types always share one id, so an identity test is a single integer compare:

```fels
if core::type_id(T) == core::type_id(Vector3) { … }
```

> **Why an id.** A `typeid` is an integer: cheap to compare, and stable across compilation
> units. With §4's tree-shaking, it costs a table slot only when it is used.

## 3. `Any`: safe dynamic values

`Any` is the workhorse of runtime reflection. It is a fat value that carries a pointer to data
and the data's type metadata.

> **Implemented today.** `Any :: struct { data: *const u8, id: usize, name: []const u8 }`
> comes from an injected prelude. `any(x)` wraps any value: it spills `x` to a temporary, points
> at it, and records `core::type_id(T)` and the type's name. The rest is ordinary generic Fels,
> so it's all type-safe: `any_as(v, T) -> ?T` (safe downcast, null on mismatch),
> `any_is(v, T) -> bool`, `any_id(v)`, `any_name(v)`. A value passed to an `Any` parameter and
> recovered by its real type works end to end, and the type *name* is available at runtime on
> the erased value. **Fels's twist on the type table:** metadata travels *inline* with the
> value, so there is no central `info_of(id)` table to bake or manage. It is also tree-shaken
> automatically, and only the names of `any()`'d types reach the binary. A bare value passed to
> an `Any` parameter is wrapped automatically. Navigation works through free functions:
> `any_field_at(v, i)`, `any_elem(v, i)` and `any_deref(v)` return a `?Any`, and
> `any_field_count(v)` and `any_field_name(v, i)` give a struct's field count and names. Fields
> are reached by index, not by name. `any_elem` and `any_deref` know the slice and pointer
> types of the program's struct fields; a slice or pointer wrapped directly (`any(xs[0..3])`)
> gives `null` (KNOWN_ISSUES). (The method spellings below, `v.info()`, `v.field("name")`,
> `v.elem(i)`, `v.deref()` and `v.as(T)`, are design only. `as` is a keyword, so the downcast is
> the function `any_as(v, T)`.)

```fels
Any :: struct { data: *const u8, id: usize, name: []const u8 }   // injected; `any(x)` builds it
```

Assigning any value to an `Any` parameter wraps it automatically. The compiler spills a
temporary and records its `typeid`:

```fels
log :: fn(label: []const u8, v: Any) { … }
log("count", 42);            // wraps i32
pos: Vector3 = .{ 1, 2, 3 };
log("pos", pos);             // wraps Vector3
```

Navigation and downcasting are **safe**. They return optionals, never UB:

```fels
v.info() -> TypeInfo                 // the type, as a matchable value
v.as(T) -> ?T                        // downcast; null if the id doesn't match
v.field("name") -> ?Any              // a struct field by name, as an Any
v.elem(i: usize) -> ?Any             // a slice/array element
v.deref() -> ?Any                    // follow a pointer/optional
```

```fels
sum_field :: fn(v: Any) -> i32 {
    if v.field("count").as(i32) |c| { return c; }   // safe: present + right type
    return 0;
}
```

> **Why checked.** `.as(T)` gives a `?T`, `.field` and `.elem` check names and bounds, and
> you pattern-match `.info()`. Reading an `Any` as the wrong type gives you a `null` to deal
> with, never a wrong value.

## 4. The type table: opt-in, tree-shaken

Runtime reflection needs `TypeInfo` baked into the binary's data segment. In Fels a type's
info reaches the binary **only if it can be reached at runtime**. That means
some runtime code calls `core::type_info(T)`, takes `core::type_id(T)`, or wraps a `T` into an
`Any`. The compiler already tracks the comptime/runtime split (the VM vs the LLVM backend), so
this is a reachability pass over those roots.

```fels
type_table() -> []TypeInfo     // every type that was baked (debuggers, tooling)
```

The result is that a hello-world binary bakes **zero** type info. A program that serializes
three structs bakes exactly those three, plus their transitive field types.

> **Why opt-in.** Binaries are small by default, with no switch to remember: reflection you
> don't use costs nothing. A capability (§7) can also gate *who* may read the table, so a
> sandboxed plugin can't list the host's types.

## 5. Serialization: one source, two speeds

> Planned: this section is design. The `Any` navigation it uses (`.info()`, `.as()`,
> `.field()`, `.elem()`) is not built yet, and today `#for` takes an integer range `a..b`, not
> a type's fields. The working serializer is `std.serde` ([07](07_stdlib.md#stdserde)).

Because the same `core::type_info` walk runs at comptime and runtime, you write a serializer
**once** and choose where it executes:

```fels
to_json :: fn(v: Any, w: *StringBuilder) {
    match v.info() {
        .boolean     => { w.str(if v.as(bool)!! { "true" } else { "false" }); },
        .int  |i|    => { w.write_i64(v.read_int()); },       // read_int widens any int
        .float |f|   => { w.write_f64(v.read_float()); },
        .slice |e|   => {
            w.byte('[');
            for i in 0..v.len() { if i > 0 { w.byte(','); } to_json(v.elem(i)!!, w); }
            w.byte(']');
        },
        .struct_ |s| => {
            w.byte('{');
            for f, i in s.fields {
                if i > 0 { w.byte(','); }
                w.quote(f.name); w.byte(':');
                to_json(v.field(f.name)!!, w);
            }
            w.byte('}');
        },
        else => { w.str("null"); },
    }
}
```

- **Runtime, dynamic:** call `to_json(some_any, w)`, and it walks `TypeInfo` at runtime. This
  handles values whose type isn't known until runtime.
- **Comptime, specialized:** under `#run`/`#for`, the *same* function monomorphizes to
  straight-line field stores with **no runtime reflection cost**. The VM folds the `match` and
  the `for`, because `core::type_info(T)` is constant.

```fels
// zero-reflection, fully specialized serializer for a known type:
to_json_of :: fn($T: type, v: T, w: *StringBuilder) {
    #for f in core::type_info(T).struct_.fields {     // unrolled at comptime
        w.quote(f.name); w.byte(':');
        to_json_of(field_type(T, f.name), field(v, f.name), w);
    }
}
```

> **Why one function.** A single function that matches on `TypeInfo` serves both: at compile
> time it folds to specialized code, at run time it runs as written, and the shared IR makes
> the two behave the same.

## 6. `constraint` and `where`: resolve-time generics

Constraints come in two layers: **named constraints** for the common, composable case, and a
**`where` block** as the escape hatch that can rewrite and reject.

### 6.1 Named constraints

> **Implemented today:** both **built-in** constraints and **user-defined
> `Name :: constraint($T) { … }` declarations**. The built-ins are `$T: Numeric`, `Int`, `Float`,
> `Signed`, `Unsigned`, `Bool`, `Struct`, `Enum` and `Ptr`, and they are checked by type kind.
> A non-satisfying type is rejected with a clear message at the `$T: Name` site
> (``type `P` does not satisfy `MyNum`: expected a numeric type``). A user `constraint` is a
> named, reusable comptime predicate: a where-style block over `core::type_info(T)` that may
> `core::reject`. It runs on the resolution VM at each `$T: Name` use, via the same two-pass
> rail. Built-ins take precedence over a same-named user constraint.
> **`core::require(T, Other)` composition works**: a top-level `core::require` guard
> recursively enforces another constraint, a user one or a built-in one (`Numeric`, `Signed`,
> …), with cycle detection, and propagates its rejection message. The constraint's own checks run after the guards. (Generic inference also binds `$T`
> from `[]$T`/`?$T`, not just `*$T`.) **Still design:** the `&` combinator below. Also,
> `core::require` is a *top-level* guard and is not evaluated inside conditional control flow.

A `constraint` is a comptime predicate over a type. It is first-class, named and composable,
and interface conformance becomes *one kind* of constraint.

```fels
Numeric :: constraint($T) {
    match core::type_info(T) { .int => {}, .float => {}, else => { core::reject("expected a numeric type"); }, }
}

Ordered :: constraint($T) { core::require(T, Numeric); }   // constraints can require others

sum :: fn($T: Numeric, xs: []T) -> T {        // `$T: Numeric` is checked at the call
    total: T = 0;
    for x in xs { total = total +% x; }
    return total;
}
```

Constraints compose with `&`, and `$T: Writer` (an interface) and `$T: Numeric` (a predicate)
use the *same* `$T: C` syntax:

```fels
serialize :: fn($T: Struct & HasField("id"), v: T) { … }   // composed
```

> **Why named.** A constraint is a value you can name, reuse and combine, and conforming to
> an interface is one more constraint, so `$T: C` covers both.

### 6.2 The `where` block: inspect, rewrite, reject

> **Implemented today (inspect + reject + output types).** A `where { … }` block after a
> generic function signature is an arbitrary comptime predicate. It runs **once per
> instantiation, during resolution**, on a resolution `ComptimeVm`, with the type parameters
> bound. It may `core::reject("msg")` to fail the instantiation with a custom message, and it
> may compute **output type params** (`-> $Acc`). Both work end to end:
>
> ```fels
> // inspect + reject:
> dbl :: fn(x: $T) -> T
> where { match core::type_info(T) { .int => {} .float => {} else => core::reject("dbl needs a numeric type"); } }
> { return x +% x; }
>
> // output type param computed by the where:
> acc_of :: fn(x: $T) -> $Acc
> where { match core::type_info(T) { .int |i| => if i.bits < 32 { Acc = i32; } else { Acc = T; }  else => Acc = T; } }
> { total: Acc = x as Acc; return total; }
> ```
>
> A satisfying type compiles, and a rejected one fails at the call site with
> `` `dbl` rejected for this type: dbl needs a numeric type``. The *binding rewrite*
> (`T = u32`) and *overload fallback* parts remain design (see `§6.3`).

When you need to *change* the bindings or compute an output type, attach a
`where` block. It runs once per instantiation, after type matching, with the type parameters as
mutable comptime values. The example below computes an output type, and it compiles and runs
today. Changing `T` itself is still design.

```fels
// Sum into a wider accumulator so u8 arrays don't overflow:
sum :: fn($T: type, xs: []T) -> $Acc
where {
    match core::type_info(T) {
        .int |i| => {
            if i.bits >= 32 { Acc = T; }
            else if i.signed { Acc = i32; }
            else { Acc = u32; }
        },
        .float   => { Acc = T; },
        else     => { core::reject("sum: not a numeric type"); },
    }
} {
    total: Acc = 0 as Acc;
    for x in xs { total = total + (x as Acc); }
    return total;
}
```

- `$Acc` is an **output type parameter**. It is declared in the return position and *computed*
  by `where`, so it reads as "the return type is whatever `where` decided."
- `core::reject("…")` takes a message, and the plan is for it to take part in **overload
  resolution**. A rejected instantiation would then *not yet* be an error, and the compiler
  would try the next overload. Only when every candidate rejects would it report, listing each
  reason. This is still design. Fels has no same-name overloads yet, so today a rejection is a
  compile error at the call site.

This is the planned shape. It does not compile today, because the second `push` is a duplicate
declaration:

```fels
// Two overloads; `where` disambiguates instead of erroring on ambiguity:
push :: fn($T: type, xs: *List(T), v: T)        where { … }   { … }
push :: fn($T: type, xs: *List(T), vs: []T)     where { … }   { … }
```

> **Why a block.** `core::reject` comes with a message, and the planned **overload fallback**
> will turn a rejection into "try the next candidate". Output types are declared where they
> belong (`-> $Acc`) and computed in `where`, whose body works on matchable `TypeInfo`.

### 6.3 How `where` is wired: two passes of resolution

The predicate runs **during generic resolution**, not after. That sounds like a chicken-and-egg
problem: "run comptime code during resolution, but the VM only exists post-sema". Fels dissolves
it by reusing the same two-pass pipeline it already has for computed `#insert #run`
(`pipeline.zig`'s `strictPass`):

1. **Tolerant pass-1 sema** type-checks everything (the `where` blocks included)
   and yields a complete-enough `FrontEnd`.
2. A **resolution `ComptimeVm`** is built from that `FrontEnd`.
3. **Strict pass-2 sema** re-checks with the VM wired into the `Checker`. The wiring is an
   opaque ctx + function-pointer callback, so sema never imports `ir` (see `WhereEvalFn` /
   `WhereTypeEvalFn`). At each generic call/instantiation the predicate runs on the VM with
   the type params bound.

**Reject** (`§6.2`): in `checkFunction`, right after the `where` block is checked and *before*
the body, the callback runs `ComptimeVm.evalWhere`. The block lowers to
`__where() -> []const u8`, with `core::reject(msg)` → `return msg` and fall-through → `""`. A
non-empty result is a resolution error at the **call site** (`origin_span` on the
instantiation). Because it comes before the body, it suppresses the spurious body errors that a
post-body check couldn't.

**Output type params** `-> $Acc`: this is parsed as an output type param
(`output_type_params`) and computed at the call site in `inferGenericCallImpl`, via
`computeOutputParamsAtCall` → `ComptimeVm.evalWhereType`. The `where` lowers so that each
`Acc = <type>` returns the **node id** of its right-hand type expression. Sema resolves that
expression (`resolveExprAsType`, with `T` bound) and binds `Acc`, so the call's return type
*and* the instantiation body both see the computed type. (Types flow back as node ids rather
than first-class `type_val`s. Those are a heavier `Any`/Phase-4 concern, while node ids need
zero new VM value machinery.)

**Still design:** **binding rewrite** (`T = u32`) and **overload fallback** (try the next
candidate on reject). Fallback is moot until Fels grows same-name overloading. Rewrite is a
small extension of the same `evalWhereType` mechanism.

## 7. What the five primitives cover

The same five primitives cover the rest of what metaprogramming usually needs, without new
directives:

| Need | In Fels |
|---|---|
| Iterating over your own types | `for x in c` calls `c.next()` until it returns `null`, for any type with a `next :: fn(self: *Self) -> ?T` method. Built (see [03](03_functions_control_flow.md#for-iterators)); an `Iter` interface for it is design. |
| Declarations made from a struct's fields (SOA, `Matrix(N)`) | A macro with `#for f in fields(T)` makes declarations from a struct's fields: functions among the declarations and methods with an `#insert` in the struct's body (built, see [13](13_metaprogramming.md#declarations)). Fields in a struct's body are design. |
| The call site's code | `#caller` builtin yielding a typed `ast.Call` you `match` on. |
| Taking code apart and putting it back | Typed macro params: a macro takes `body: ast.Block` (matchable) instead of opaque `Code`, and you rebuild and `#insert`. |
| Every type of the program | `type_table()`, tree-shaken and gated by a capability. |
| Whether code runs at compile time | `#phase` builtin (`.comptime` / `.runtime`), foldable in `#if`. |
| Keeping a plugin away from the host | Reflection and FFI behind capabilities: a plugin gets `Reflect`/`FileSys` capabilities, or it cannot reach the host. |

So **reflection is a value, constraints are predicates over it, `Any` is reflection plus a
pointer, iteration is an interface, and code generation is a `#for` over reflected fields.**
Each piece is type-checked, and each works the same at compile time and at run time.

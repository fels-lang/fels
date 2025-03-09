# K2 Reflection, `Any`, and Constraints — Design

> Status: **Phase 1 IMPLEMENTED** (matchable `TypeInfo` + comptime `type_info`).
> **Phase 2 PARTIAL**: built-in composable constraints (`$T: Numeric`/`Int`/
> `Float`/`Signed`/`Unsigned`/`Struct`/`Enum`/`Ptr`/`Bool`) are checked at
> resolution with clear reject messages. **User-defined `where { … }` blocks with
> `reject("msg")` are IMPLEMENTED** (deferred evaluation): the predicate is an
> arbitrary comptime block that inspects `type_info(T)` and may `reject`, run on
> the comptime VM per instantiation (`§6.2`). Still design: named `constraint`
> declarations, binding *rewrite* / output type params (`-> $Acc`), and overload
> fallback (these need the predicate during *overload selection* in sema, not just
> at lowering — see `§6.3`). Phases 3–6 are design. Sister to
> [`09_comptime_vm_roadmap.md`](09_comptime_vm_roadmap.md). Describes runtime type
> information, the `Any` type, reflection-driven serialization, and resolve-time
> generic constraints (`where`). The goal is to match Jai's metaprogramming reach
> and **exceed** it — not by copying its directives, but by deriving everything
> from a few orthogonal, type-safe primitives.

## Design thesis

Jai exposes reflection and metaprogramming through many special-purpose pieces
that don't compose: `#modify` (a code block bolted onto a signature), the
`Type_Info` / `Type_Info_Integer` / `Type_Info_Struct` cast hierarchy,
`get_type_table`, `for_expansion`, `#insert -> string`. Each is powerful; together
they're a grab-bag.

K2 already has a structural advantage Jai lacks: **the comptime VM executes the
same IR as the runtime backend**, so comptime and runtime behave identically (an
`#run` FNV-1a hash equals its runtime value bit-for-bit). We lean on that to make
*one* reflection surface serve both phases.

Five orthogonal primitives, each type-safe, each composing with the rest:

1. **`TypeInfo`** — a matchable tagged enum describing a type. Same value at
   comptime and runtime.
2. **`typeid`** — a cheap, stable runtime identity for a type (an index, not a
   pointer).
3. **`Any`** — a `(pointer, typeid)` pair with *safe* navigation and downcasting.
4. **`constraint`** — a comptime predicate over `TypeInfo`; `$T: C` and interface
   conformance are the same mechanism.
5. **`where`** — a per-instantiation block that can inspect, *rewrite*, and
   *reject* the type bindings, with overload fallback.

Reflection-driven serialization, custom iteration, and code generation all fall
out of these — no new directives.

---

## 1. `TypeInfo` — reflection as a matchable value

Today K2 has `type_info(T)` with ad-hoc field access (`.kind`, `.fields[i].name`,
`.bits`). We replace that with a real tagged enum — the same shape as the `ast.*`
metaprogramming surface, injected as a prelude when reflection is used.

```k2
TypeInfo :: enum {
    void,
    bool,
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
    distinct: DistinctInfo,   // { name, underlying: *TypeInfo }
}

FieldInfo   :: struct { name: []const u8, ty: *TypeInfo, offset: usize, is_const: bool }
VariantInfo :: struct { name: []const u8, payload: ?*TypeInfo, tag: u32 }
```

`type_info(T) -> TypeInfo` folds at comptime *and* is available at runtime (see
§4). Because it's a tagged enum, you inspect it by `match`, not by casting:

```k2
describe :: fn(info: TypeInfo) -> []const u8 {
    match info {
        .int |i|     => return if i.signed { "signed integer" } else { "unsigned integer" };
        .struct_ |s| => return s.name;
        .slice |elem| => return "slice";
        else         => return "other";
    }
}
```

> **✦ Beyond Jai.** Jai forces `if t.type == .INTEGER { info := cast(*Type_Info_Integer) t; … }`
> — a tag check followed by an unchecked pointer cast. K2's `match info { .int |i| => … }`
> is exhaustive, payload-bound, and impossible to mis-cast. The compiler also
> checks you handled (or `else`'d) every kind.

---

## 2. `typeid` — cheap runtime identity

```k2
typeid(T) -> typeid          // a small, stable id (usize-sized)
typeid_of(any_value) -> typeid
info_of(id: typeid) -> *TypeInfo   // the table lookup
```

A `typeid` is an index into the (tree-shaken) type table, not a pointer. Two
identical types always share one id, so identity tests are a single integer
compare:

```k2
if typeid_of(x) == typeid(Vector3) { … }
```

> **✦ Beyond Jai.** Jai compares `*Type_Info` pointers and bakes the whole table
> unconditionally. A `typeid` is cheaper to compare, stable across compilation
> units, and (with §4's tree-shaking) only costs a table slot when actually used.

---

## 3. `Any` — safe dynamic values

`Any` is the runtime-reflection workhorse: a fat value carrying a pointer to data
and the data's `typeid`.

```k2
Any :: struct { data: *u8, id: typeid }   // conceptually; constructed by the compiler
```

Assigning any value to an `Any` parameter wraps it automatically (the compiler
spills a temporary and records its `typeid`):

```k2
log :: fn(label: []const u8, v: Any) { … }
log("count", 42);            // wraps i32
log("pos", Vector3.{1,2,3}); // wraps Vector3
```

Navigation and downcasting are **safe** — they return optionals, never UB:

```k2
v.info() -> TypeInfo                 // the type, as a matchable value
v.as(T) -> ?T                        // downcast; null if the id doesn't match
v.field("name") -> ?Any              // a struct field by name, as an Any
v.elem(i: usize) -> ?Any             // a slice/array element
v.deref() -> ?Any                    // follow a pointer/optional
```

```k2
sum_field :: fn(v: Any) -> i32 {
    if v.field("count").as(i32) |c| { return c; }   // safe: present + right type
    return 0;
}
```

> **✦ Beyond Jai.** Jai's `Any` is `{ value_pointer, type }` and you cast it
> yourself (unchecked). K2's `.as(T)` is an `?T`, `.field`/`.elem` are bounds- and
> name-checked, and you pattern-match `.info()`. You cannot read an `Any` as the
> wrong type without the compiler handing you a `null` to deal with.

---

## 4. The type table — opt-in, tree-shaken

Runtime reflection needs `TypeInfo` baked into the binary's data segment. Jai
bakes **everything** (then offers `runtime_storageless_type_info` to turn it off).
K2 inverts the default: a type's info reaches the binary **only if it can be
reached at runtime** — i.e. some runtime code calls `type_info(T)`, takes
`typeid(T)`, or wraps a `T` into an `Any`. The compiler already tracks the
comptime/runtime split (the VM vs the LLVM backend), so this is a reachability
pass over those roots.

```k2
type_table() -> []TypeInfo     // every type that was baked (debuggers, tooling)
```

Result: a hello-world binary bakes **zero** type info; a program that serializes
three structs bakes exactly those three (plus their transitive field types).

> **✦ Beyond Jai.** Smaller binaries by default, with no global switch to
> remember. Reflection you don't use costs nothing — the opposite of Jai's
> bake-all-then-strip model. A capability (§7) can additionally gate *who* may read
> the table, so a sandboxed plugin can't enumerate the host's types.

---

## 5. Serialization — one source, two speeds

Because the same `type_info` walk runs at comptime and runtime, you write a
serializer **once** and choose where it executes:

```k2
to_json :: fn(v: Any, w: *StringBuilder) {
    match v.info() {
        .bool        => w.str(if v.as(bool)!! { "true" } else { "false" }),
        .int  |i|    => w.write_i64(v.read_int()),       // read_int widens any int
        .float |f|   => w.write_f64(v.read_float()),
        .slice |e|   => {
            w.byte('[');
            for i in 0..v.len() { if i > 0 { w.byte(','); } to_json(v.elem(i)!!, w); }
            w.byte(']');
        }
        .struct_ |s| => {
            w.byte('{');
            for f, i in s.fields {
                if i > 0 { w.byte(','); }
                w.quote(f.name); w.byte(':');
                to_json(v.field(f.name)!!, w);
            }
            w.byte('}');
        }
        else => w.str("null"),
    }
}
```

- **Runtime, dynamic:** call `to_json(some_any, w)` — walks `TypeInfo` at runtime.
  Handles values whose type isn't known until runtime.
- **Comptime, specialized:** the *same* function under `#run`/`#for` monomorphizes
  to straight-line field stores with **no runtime reflection cost** — the VM folds
  the `match` and the `for` because `type_info(T)` is constant.

```k2
// zero-reflection, fully specialized serializer for a known type:
to_json_of :: fn($T: type, v: T, w: *StringBuilder) {
    #for f in type_info(T).struct_.fields {     // unrolled at comptime
        w.quote(f.name); w.byte(':');
        to_json_of(field_type(T, f.name), field(v, f.name), w);
    }
}
```

> **✦ Beyond Jai.** Jai makes you pick *up front*: write a string-codegen
> serializer (`#insert -> string` + `String_Builder`, see its `for_each_member`),
> **or** walk `Type_Info` at runtime. They're different code. K2's single
> `match`-on-`TypeInfo` function *is* both — comptime folds it to specialized code,
> runtime executes it dynamically, guaranteed identical by the shared IR.

---

## 6. `constraint` and `where` — resolve-time generics

This replaces Jai's `#modify`. Two layers: **named constraints** (the common,
composable case) and a **`where` block** (the escape hatch that can rewrite and
reject).

### 6.1 Named constraints

> **Implemented today:** the **built-in** constraints `$T: Numeric`, `Int`,
> `Float`, `Signed`, `Unsigned`, `Bool`, `Struct`, `Enum`, `Ptr` are checked at
> instantiation by type kind, and a non-satisfying type is rejected with a clear
> message (`type `P` does not satisfy `Numeric`: expected a numeric type`). They
> use the same `$T: C` syntax as interface conformance. (Generic inference now
> also binds `$T` from `[]$T`/`?$T` arguments, not just `*$T`.) **User-defined**
> `constraint` declarations below remain design.

A `constraint` is a comptime predicate over a type — first-class, named, and
composable. Interface conformance becomes *one kind* of constraint.

```k2
Numeric :: constraint($T) {
    match type_info(T) { .int, .float => accept; else => reject("expected a numeric type"); }
}

Ordered :: constraint($T) { require(T, Numeric); }   // constraints can require others

sum :: fn($T: Numeric, xs: []T) -> T {        // `$T: Numeric` is checked at the call
    total: T = 0;
    for x in xs { total = total +% x; }
    return total;
}
```

Constraints compose with `&`, and `$T: Writer` (an interface) and `$T: Numeric`
(a predicate) use the *same* `$T: C` syntax:

```k2
serialize :: fn($T: Struct & HasField("id"), v: T) { … }   // composed
```

> **✦ Beyond Jai.** Jai's `#modify` is an anonymous code block (or a proc returning
> `bool`) glued to one signature — not nameable, not composable, and orthogonal to
> interface constraints. K2 makes the predicate a named, reusable, composable
> value, and *unifies* interface conformance with arbitrary predicates. One
> concept (`$T: C`) instead of two (`#modify` + interface `/Type`).

### 6.2 The `where` block — inspect, rewrite, reject

> **Implemented today (inspect + reject).** A `where { … }` block after a generic
> function signature is an arbitrary comptime predicate. It runs **once per
> instantiation**, on the comptime VM, with the type parameters bound. It may
> `reject("msg")` to fail the instantiation with a custom message. The canonical
> form works end to end:
>
> ```k2
> dbl :: fn(x: $T) -> T
> where { match type_info(T) { .int => {} .float => {} else => reject("dbl needs a numeric type"); } }
> { return x +% x; }
> ```
>
> A satisfying type compiles; a rejected one fails with
> `` `dbl` rejected for this type: dbl needs a numeric type``. The *rewrite* /
> output-type / overload-fallback parts below remain design (see `§6.3`).

When you need to *change* the bindings (Jai's `T = s64`) or compute an output
type, attach a `where` block. It runs once per instantiation, after type matching,
with the type parameters as mutable comptime values.

```k2
// Sum into a wider accumulator so u8 arrays don't overflow:
sum :: fn($T: type, xs: []T) -> $Acc
where {
    match type_info(T) {
        .int |i| => Acc = if i.bits < 32 { (if i.signed { i32 } else { u32 }) } else { T };
        .float   => Acc = T;
        else     => reject("sum: {type_name(T)} is not a numeric type");
    }
} {
    total: Acc = 0;
    for x in xs { total = total +% (x as Acc); }
    return total;
}
```

- `$Acc` is an **output type parameter** — declared in the return position,
  *computed* by `where`. (Jai bolts this on with a separate `$R` and assigns it
  inside `#modify`; here it reads as "the return type is whatever `where` decided.")
- `reject("…")` takes an interpolated message and, crucially, participates in
  **overload resolution**: a rejected instantiation is *not yet* an error — the
  compiler tries the next overload. Only when every candidate rejects does it
  report, listing each reason.

```k2
// Two overloads; `where` disambiguates instead of erroring on ambiguity:
push :: fn($T: type, xs: *List(T), v: T)        where { … }   { … }
push :: fn($T: type, xs: *List(T), vs: []T)     where { … }   { … }
```

> **✦ Beyond Jai.** Three improvements: (1) `reject` with a real interpolated
> message and **overload fallback** instead of a hard error (Jai's `#modify`
> returning false is fatal); (2) output types are *declared where they belong*
> (`-> $Acc`) and computed in `where`, instead of a magic `$R` mutated in a side
> block; (3) the `where` body uses matchable `TypeInfo`, not `cast(*Type_Info_*)`.

### 6.3 How `where` is wired (and what's next)

The predicate is evaluated by the **deferred** strategy: sema type-checks the
`where` block as comptime code (with the type params in scope, `reject` a void
builtin), but does *not* run it. At **IR lowering**, where the comptime VM already
exists, each generic instantiation lowers its `where` block to a throwaway
comptime function `__where() -> []const u8` — `reject(msg)` lowers to `return msg`,
falling off the end returns `""` (accept) — and runs it on the VM with `T` bound.
A non-empty result is the rejection message; lowering fails with it.

This sidesteps the chicken-and-egg of "run comptime code during resolution" (the
VM only exists post-sema) by deferring the check to the point where the VM is
ready. Key wiring: `lowerWhereToFunction` / `ComptimeVm.evalWhere` in `ir.zig`
(uses the **per-instantiation** `expr_types`, so the `match type_info(T)` subject
resolves to `TypeInfo`), `in_where` mode on the `FunctionLowerer` (turns `reject`
into a `return`), and the instantiation loop in `lowerModuleInner` which calls
`evalWhere` before lowering the body.

**What deferred eval gives up** (and why the full feature needs the *two-pass
resolution* of `§6.1`'s note): the check runs *after* overload selection and
*after* the body is type-checked, so it can only **inspect + reject** — it cannot
do **binding rewrite** (`T = u32`), **output type params** (`-> $Acc`), or
**overload fallback** (try the next candidate on reject). Those require the
predicate to run *during* overload selection in sema. The planned path is the
two-pass pipeline K2 already uses for computed `#insert #run`: tolerant pass-1
sema → build a resolution VM from the predicates → strict pass-2 sema that runs
them during resolution. Deferred eval is the stepping stone; it covers the common
single-function `reject` case now.

---

## 7. Where it all pays off (broad feature parity, K2-style)

The same five primitives subsume the rest of Jai's metaprogramming toolkit —
without new directives:

| Jai feature | K2 realization | Improvement |
|---|---|---|
| `for_expansion` (custom iterators) | An `Iter` **interface**: `Iter :: interface { next :: fn(self: *Self) -> ?Elem; }`. `for x in c` desugars to `next()`. | Works at runtime *and* comptime; composes with dynamic dispatch; not a macro you reimplement per container. A `#for_expansion` macro stays available for zero-cost unrolling when you want it. |
| `#insert -> string` building **struct fields** (SOA, `Matrix(N)`) | `#for f in type_info(T).fields { #emit_field … }` inside a struct body — typed field emission, not string concatenation. | Generated fields are type-checked at the generation site; no `.added_strings.jai` to eyeball. |
| `#caller_code` (call-site AST) | `#caller` builtin yielding a typed `ast.Call` you `match` on. | Typed AST, not `cast(*Code_Procedure_Call)`. |
| `compiler_get_nodes` / `compiler_get_code` (arbitrary code AST round-trip) | Typed macro params: a macro takes `body: ast.Block` (matchable) instead of opaque `Code`; rebuild and `#insert`. | Type-safe AST surgery — match on `ast.*`, never cast `Code_Node*`. |
| `get_type_table` | `type_table()` — but tree-shaken and capability-gated. | Smaller binaries; sandboxable. |
| `#compile_time` | `#phase` builtin (`.comptime` / `.runtime`), foldable in `#if`. | — |
| (none) | **Capability-sandboxed reflection + FFI** | The structural supply-chain fix: a plugin gets `Reflect`/`FileSys` capabilities or it physically can't reach the host. Jai has no equivalent. |

The unifying idea: **reflection is a value, constraints are predicates over it,
`Any` is reflection plus a pointer, iteration is an interface, and code generation
is a `#for` over reflected fields.** Five composable pieces instead of a dozen
special forms — all type-checked, all phase-unified, all sandboxable.

---

## 8. Implementation phasing

Each phase is independently useful and testable.

1. **`TypeInfo` as a tagged enum + comptime `type_info(T)`.** Reuse the `ast.*`
   prelude-injection machinery. Port the existing ad-hoc reflection to `match`.
   (Pure comptime; no runtime cost yet.)
2. **`constraint` + `where`.** Resolve-time predicate evaluation on the VM (it can
   already run comptime code over `type_info`); reject-with-fallback in overload
   resolution; output type params.
3. **`typeid` + the tree-shaken type table.** Reachability pass over runtime roots;
   emit `TypeInfo` constants into the data segment (now that aggregate `#run`
   constants are needed — this also motivates finishing aggregate const baking).
4. **`Any` + safe navigation.** Auto-wrap at `Any` boundaries; `.as`/`.field`/
   `.elem` lowering; runtime `to_json`-style serialization.
5. **Iteration interface + struct-field `#for` + typed macro params.** The broad
   ergonomics layer.
6. **Capability gating.** Fold reflection/FFI into the Phase-5 capability system.

Phases 1–2 are the highest leverage (constraints unblock real generic libraries),
need no backend work, and lean on machinery that already exists. Phase 3 is the
one with real new backend work (baking aggregate `TypeInfo` into the binary).

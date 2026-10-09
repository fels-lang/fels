# Functions & Control Flow

## Function Declarations

You declare a function with `::` and `fn`:

```fels
// Named function
add :: fn(a: i32, b: i32) -> i32 {
    return a + b;
}

// Public function (exported from module)
pub multiply :: fn(a: i32, b: i32) -> i32 {
    return a * b;
}

// Function with no return value
greet :: fn() {
    println("hello");
}

// Function returning void explicitly
process :: fn(data: []const u8) -> void {
    // ...
}
```

> [!NOTE]
> A function without an explicit return type returns `void` implicitly. You may still write
> `-> void` if you find it clearer, but you don't have to.

A constant whose value names a function is that function under another name, in the same way
that `X :: Name;` is the type it names. Calling the constant calls the function directly, and
its value is the function's.

```fels
seven :: fn() -> i32 { return 7; }
F :: seven;                 // F() is seven(); `h := F;` holds seven
Print :: io::println;       // a function of another module, by a shorter name
```

## Parameters

```fels
// Value parameters
add :: fn(a: i32, b: i32) -> i32 { ... }

// Pointer parameters (allows mutation)
increment :: fn(value: *i32) {
    *value += 1;
}

// Slice parameters
sum :: fn(values: []const i32) -> i32 { ... }

// Borrow parameters (for zone-owned values)
fill :: fn(data: borrow []u8) {
    data[0] = 42u8;
}

// Self parameter (enables dot-call syntax)
pub doubled :: fn(self: i32) -> i32 {
    return self * 2;
}
// Called as: x.doubled() or doubled(x)
```

| Parameter Style | Syntax            | Semantics                                      |
|-----------------|-------------------|-------------------------------------------------|
| Value           | `a: i32`          | Passed by value (copy)                          |
| Pointer         | `p: *i32`         | Mutable pointer to a value                      |
| Const pointer   | `p: *const i32`   | Read-only pointer to a value                    |
| Slice           | `s: []const u8`   | Read-only view into contiguous memory            |
| Borrow          | `b: borrow []u8`  | Zone-aware borrowed reference                   |
| Self            | `self: T`         | Enables dot-call syntax on type `T`             |

## Self and Methods

Any top-level function whose first parameter is named `self` can be called with **dot-call
syntax**:

```fels
// In module point.fels:
pub distance :: fn(self: *Point) -> f64 { ... }

// Calling:
p: Point = .{ 3, 4 };
d := p.distance();      // auto-referenced to `&p`; same as distance(&p)
```

A `*Self` method auto-references its receiver, so you call it on a plain value, without an
explicit `&`. It works on a **temporary** too: the value is spilled to a stack slot, and the
method gets a pointer to it. The other way round, a method that takes the value is called
through a pointer as it is: `self.get()` in a `*Self` method passes `*self`. Methods also chain
on returned values:

```fels
n := make_point(3, 4).distance();        // call on a temporary
q := origin().translate(1, 2).scaled(3); // chain method calls
```

> [!NOTE]
> A method on a temporary receiver sees a copy, so any change it makes is thrown away
> together with the temporary. Chaining is for transforming and reading.

## Generic Functions

Fels uses the `$` prefix to introduce type parameters. The first occurrence of `$T` binds the
type, and later uses of `T` refer to that bound type.

```fels
// Type parameter with $
identity :: fn(value: $T) -> T {
    return value;
}

// Multiple type params
swap :: fn(a: $T, b: $U) -> U { ... }

// A type parameter of its own
max :: fn($T: type, a: T, b: T) -> T {
    if a > b { return a; }
    return b;
}
// Called as max(i32, 10, 20), or max(10, 20)

// Constrained type param (must implement interface)
print_to :: fn($W: Writer, writer: *W, data: []const u8) -> usize ! IoError {
    return writer.write(data)?;
}
```

A type parameter declared in the list (`$T: type`, or `$W: Writer` with a constraint) is an
argument that the caller may pass or leave to inference. A call passes its type arguments
before the values, and it can pass the `$T: type` ones, all of them, or none. Each one you
don't pass is inferred from the values, so `max(10, 20)` makes `T` an `i32`. One that cannot
be inferred has to be passed, like the `T` of `make :: fn($T: type) -> T`, which you call as
`make(i64)`.

A pointer type is a type argument like any other, as in `arena.new_slice(*Node, n)` or
`core::sizeof(**Node)`. Where a type is expected, `*Node` is that pointer type. That is the
case for the first argument of `core::sizeof`, `core::ptr_from_int` and the other builtins
that take one, and for an explicit `$T: type` argument of a generic function. In any other
argument `*p` is a dereference, so `f(*p)` loads through the pointer `p`.
(`core::sizeof(*p)` with a variable `p` is the size of what `p` points to.)

> [!NOTE]
> Generics are **monomorphized**: each unique type argument produces a specialized version
> at compile time, so there is no runtime dispatch overhead.

## Lambdas (Anonymous Functions)

An expression of the form `fn(params) -> Ret { body }` is a **lambda**. It is an anonymous
function that you can pass directly to a higher-order function or store in a variable. The
return type is optional and defaults to `void`.

```fels
// As an argument: no need to declare a named predicate.
n := slice::count_where(i32, xs, fn(x: i32) -> bool { return x < 0; });

// Stored in a local, then called.
twice := fn(x: i32) -> i32 { return x * 2; };
y := twice(21); // 42

// A bare function name is itself a value:
sq := square;   // square is a top-level fn
z := sq(8);
```

Functions are first-class values. A function name (or a lambda) has a **function-pointer
type** `fn(Params) -> Ret`, and you can write that type out explicitly:

```fels
op: fn(i32, i32) -> i32 = add;
r := op(2, 3);
```

### Capturing closures

A lambda may use variables from the enclosing scope. They are **captured by value** at the
moment the closure is created:

```fels
mul :: fn(f: fn(i32) -> i32, v: i32) -> i32 { return f(v); }

main :: fn() -> i32 {
    factor: i32 = 10;
    scale := fn(x: i32) -> i32 { return x * factor; }; // captures `factor`
    return mul(scale, 4); // 40
}
```

A lambda in a generic function may use the function's values and its type parameters, as
the rest of its body may. It is made once per instantiation of the function:

```fels
apply :: fn(n: usize, f: fn(usize)) { for i in 0..n { f(i); } }

scale_all :: fn($T: type, xs: []T, out: []T, by: T) {
    apply(xs.len, fn(i: usize) { out[i] = xs[i] * by; });
}
```

A function value is a **fat closure** `{ fn, env }`: a function pointer plus a pointer to
its captured environment. A plain (non-capturing) function or lambda has an empty
environment, so it costs no more than a bare pointer. A capturing lambda copies the captured
values into a small environment when it is created.

**Where the environment lives** follows Fels's region model:

- Inside a `zone`, a capturing closure's environment is allocated on the **zone's
  Arena**. The closure is then valid for the whole zone, and you can store it and hand it
  around freely within that scope:

  ```fels
  zone scratch: Arena {
      base: i32 = 100;
      f := fn(x: i32) -> i32 { return base + x; }; // env on `scratch`
      r := call_it(f, 7);                           // safe anywhere in the zone
  }
  ```

- When there is an `*Arena` parameter, the environment is allocated in that
  **caller-supplied region**. This is region passing, and it lets a factory *return* an
  escaping closure that stays valid for as long as the caller's arena:

  ```fels
  make_adder :: fn(into: *Arena, n: i32) -> fn(i32) -> i32 {
      return fn(x: i32) -> i32 { return x + n; }; // env allocated in `into`
  }

  zone z: Arena {
      add5 := make_adder(&z, 5);
      r := add5(10); // 15: `add5` outlives `make_adder`, valid for the zone
  }
  ```

- Otherwise, the environment lives on the **stack frame** that created it. Such a closure
  is safe to *call* and to *pass down* to a higher-order function, which is the common
  case, but it cannot outlive that frame.

> [!IMPORTANT]
> **Returning a capturing closure requires an `*Arena` parameter**, so that the environment
> lives in the caller's region. Without one it is a compile error. The environment belongs
> to a stack frame or a zone that ends with the function, so it would dangle:
> ```
> error: a capturing closure cannot be returned: its captured environment lives
> in this function and would be left dangling (take an `*Arena` parameter so the
> closure's environment is allocated in the caller's region)
> ```
> This applies whether you return the closure directly or through a local. Returning a
> *non*-capturing function value is always fine, because it is only a pointer.

> [!NOTE]
> Lambdas are **lifted** to ordinary top-level functions at compile time. A non-capturing
> lambda becomes a named function and a pointer, and nothing more.

> [!NOTE]
> Function values also work at **compile time**. A higher-order call evaluated in `#run` (or
> any comptime context) folds to a constant, for non-capturing and capturing closures alike.
> One edge case: an inline lambda used *directly* as an argument in a top-level constant
> initializer isn't supported yet. Bind it to a local first
> (`f := fn(x){ … }; K :: #run g(f);`) or use a named function.

## Fallible Functions

A function that can fail declares an error channel with `!` after the return type:

```fels
// Named error type
read :: fn(buf: []u8) -> usize ! IoError { ... }

// Inline error set
parse :: fn(s: []const u8) -> i32 ! { invalid, overflow } { ... }

// Inferred error type
combine :: fn() -> i32 ! { ... }
```

> [!TIP]
> See the [Error Handling](04_error_handling.md) chapter for full details on error
> propagation, `catch`, and the `?` operator.

## External Functions

To call C or system functions, you write an FFI declaration with the `#extern` attribute:

```fels
#extern("kernel32", "GetStdHandle")
GetStdHandle :: fn(id: i32) -> usize;

#extern("kernel32", "WriteFile")
WriteFile :: fn(
    handle: usize,
    buf: *const u8,
    len: u32,
    written: *u32,
    overlapped: ?*void,
) -> bool;
```

> [!WARNING]
> Calls to external functions are inherently unsafe, because the compiler cannot verify that
> the foreign function's signature or behavior is correct.

## Function Attributes

Attributes go before the function declaration and change how it is compiled:

```fels
#inline
pub fast_add :: fn(a: i32, b: i32) -> i32 { return a + b; }

#noinline
slow_path :: fn() { ... }

#noreturn
abort :: fn() { ... }

#naked
asm_entry :: fn() { ... }

#entry
custom_entry :: fn() { ... }

#export
exported_fn :: fn() { ... }
```

| Attribute    | Effect                                                        |
|--------------|---------------------------------------------------------------|
| `#inline`    | Hint to always inline the function at call sites              |
| `#noinline`  | Prevent the function from being inlined                       |
| `#noreturn`  | Declares the function never returns (e.g., `abort`, `exit`)   |
| `#naked`     | Omit the function prologue/epilogue (for raw assembly)        |
| `#entry`     | Mark as the program entry point                               |
| `#export`    | Export the symbol for external linkage                         |

## Control Flow

### If / Else

```fels
if x > 0 {
    println("positive");
} else {
    println("non-positive");
}

// Without else
if flag {
    do_something();
}

// Unwrapping an optional: try_parse returns one
if try_parse(input) |value| {
    // value is the unwrapped payload
} else {
    // try_parse returned null
}
```

The name goes after the optional, the same way `while opt |x|` and `match … |p|` bind it.
The older spelling `if x := opt { … }` still compiles, but with a warning.

You can chain `else if`, and each one desugars to a nested `if` inside the `else`:

```fels
if x > 0 {
    // positive
} else if x == 0 {
    // zero
} else {
    // negative
}
```

#### If as an expression

In value position, `if` produces a value. Each branch is a single expression in braces, and
the `else` is mandatory, because an expression must always yield something:

```fels
sign := if n > 0 { 1 } else if n < 0 { -1 } else { 0 };

mode: u32 = if enabled { 1u32 } else { 0u32 };   // branch literal takes the type

return base + if hit { bonus } else { 0 };        // anywhere an expression fits
```

The two branches must have compatible types. The expected type flows into the branches, so
an untyped branch value (`.{ … }`, a bare `.variant`) is typed from context, exactly as in a
`match` expression. (Statement-position `if { … }` is unchanged. The expression form only
applies where a value is required.)

### While Loop

```fels
i := 0;
while i < 10 {
    println("loop");
    i += 1;
}
```

For an infinite loop, write `while true`:

```fels
while true {
    // runs forever until break
    if should_stop() { break; }
}
```

**Optional-unwrap loop**: `while opt |x|` re-evaluates `opt` on each iteration, binds the
unwrapped payload to `x`, and exits when `opt` is null. It is the clean way to walk a linked
structure or drain an iterator:

```fels
cur: ?*Node = head;
while cur |n| {
    visit(n.val);
    cur = n.next;
}
```

The condition may be any optional, and the `|x|` binding is itself optional:
`while opt { … }` loops while `opt` is non-null without binding the payload.

### For Range Loop

```fels
// Exclusive range: 0, 1, 2, ..., 9
for i in 0..10 {
    println("{i}");
}

// Inclusive range: 0, 1, 2, ..., 10
for i in 0..=10 {
    println("{i}");
}
```

| Syntax     | Range            | Example values        |
|------------|------------------|-----------------------|
| `0..10`    | Exclusive end    | 0, 1, 2, …, 9        |
| `0..=10`   | Inclusive end     | 0, 1, 2, …, 10       |

The index has the type of the bounds. A literal bound takes the type of the other bound, so
`for i in 0..xs.len` counts in `usize` and `i` indexes `xs` as it is. When both bounds are
literals, as in `0..10`, the index takes the type its uses ask for, like a local inferred
from a literal (see [Types](02_types.md)). When no use asks for one, it is an `i32`.

### For Slice Loop

```fels
data: [4]i32 = .{ 10, 20, 30, 40 };

// By value
for val in data[:] {
    println("{val}");
}

// With index
for val, idx in data[:] {
    // val is the element, idx is the index
}

// By reference
for &val in data[:] {
    *val += 1; // modify in-place
}
```

> [!TIP]
> Use `data[:]` to create a slice from a fixed-size array. See the [Type System](02_types.md)
> chapter for more on slices and arrays.

### For Iterators

`for x in it` also works over any value whose type has a method `next(self: *Self) -> ?T`.
Each iteration calls `next` and binds the unwrapped payload, and the loop stops when `next`
returns `null`. That is exactly what `while it.next() |x| { … }` does, but the loop plumbing
stays out of sight.

```fels
Range :: struct { cur: i32, end: i32 }

// The iterator protocol: advance and yield, or return null when exhausted.
next :: fn(self: *Range) -> ?i32 {
    if self.cur >= self.end { return null; }
    v := self.cur;
    self.cur = self.cur + 1;
    return v;
}

main :: fn() -> i32 {
    r: Range = .{ 1, 5 };
    sum: i32 = 0;
    for x in r { sum = sum + x; } // 1 + 2 + 3 + 4 = 10
    return sum;
}
```

The index form `for x, i in it` is available too, and `i` counts iterations from `0`.
Iterating by reference (`for &x in it`) is not allowed, because a `next` method yields
values, not addresses.

### For Collections

A collection, a value whose type has a method `items(self) -> []T` such as `Vec`, loops over
the slice `items()` returns. So `for x in v` is `for x in v.items()`, and the index and
by-reference forms work as they do on a slice:

```fels
v := vec::make(i32, &a);
v.push(10);
v.push(20);
for x in v { total += x; }
for x, i in v { println("v[{i}] = {x}"); }
for &x in v { *x = *x * 2; }      // writes into the Vec
```

A type with a `next` method loops as an iterator, even if it has an `items` method too.

### Match

`match` does pattern matching on enums and integers. An arm is `pattern => body,`. In a
match statement the body is a block or a single statement, and in a match expression it is a
value. The parser does not require the comma, but the style is a comma after each arm. A
match on one line may leave out the last one. In a match expression the comma also keeps a
value apart from the next pattern, because `x .zero` without it reads as `x.zero`. An arm of
a single statement, such as `.a => return 1;`, is written with just its own `;`:

```fels
// Enum matching
match direction {
    .north => { println("going north"); },
    .south => { println("going south"); },
    .east  => { println("going east"); },
    .west  => { println("going west"); },
}

// Several variants that share an arm
match kind {
    .buy, .sell => { /* moves shares */ },
    else        => { /* the rest */ },
}

// Enum with payload capture (an arm of one variant)
match shape {
    .circle    |radius| => { /* use radius */ },
    .rectangle |corner| => { /* use corner */ },
    .none               => { /* nothing */ },
}

// Integer matching: single values, grouped values, and ranges
match code {
    0        => { println("ok"); },
    1, 2, 3  => { println("warning"); }, // grouped cases
    400..=499 => { println("client"); }, // inclusive range (use `..` for exclusive)
    else     => { println("error"); },
}

// String matching
match command {
    "start"        => { /* ... */ },
    "stop", "halt" => { /* grouped */ },
    else           => { /* ... */ },
}

// A bare name binds the subject (a catch-all); `if` adds a guard
match n {
    0          => { /* zero */ },
    k if k < 0 => { /* negative, bound as k */ },
    k          => { /* positive, bound as k */ },
}

// Single-statement arms (no braces needed)
match value {
    .a   => return 1;
    .b   => return 2;
    else => return 0;
}

// Match as an expression: each arm yields a value, the whole match is that value
sign := match n {
    .neg  => -1,
    .zero => 0,
    .pos  => 1,
};

// Works in any value position: return, call arguments, initializers, arithmetic
return match code { 0 => 200, 1, 2, 3 => 400, else => 500 };
```

> [!IMPORTANT]
> A match on an enum is **exhaustiveness-checked**. Every variant must be handled, or an
> `else` arm or a catch-all name must be present. Otherwise the compiler reports an error
> (*"non-exhaustive match: variant `.west` is not handled"*). A **total** match (one that
> covers every variant) needs no `else`. Because it is provably exhaustive, it also **counts
> as returning on all paths**, so a function whose body is only a total match over `return`
> arms type-checks without a trailing `return`. A **duplicate** arm for the same variant is
> rejected. Integer matches are unbounded, so only an `else` or a catch-all name (`k => …`)
> makes them exhaustive.

> [!IMPORTANT]
> **Match as an expression**: in value position each arm is `pattern => value`, where the
> value is an expression and the arms are separated by commas. All arms must unify to one
> type, and the match must be **exhaustive**, so that it produces a value on every path. A
> non-exhaustive value-match is an error. Untyped arm values (`.{ … }`, bare `.variant` enum
> literals) take their type from context (`c: C = match …`, a `return`, a call argument).

> [!NOTE]
> **Patterns**: an arm can match enum variants (`.name`, optionally with a `|payload|`
> capture) and integer values (single or grouped `1, 2, 3`, negative `-1`, or characters
> `'a'`). It can match integer **ranges** (`1..5` exclusive, `'a'..='z'` inclusive), and
> values and ranges mixed in one arm (`'0'..='9', '_'`). It can also match **string**
> literals (single or grouped), a bare **name** (which binds the subject as a catch-all), or
> be `else`. Any arm may carry a **guard** `if <bool>`. The guard is evaluated after the
> binding, and a failing guard falls through to the next arm. A guarded arm does not count
> toward exhaustiveness. String compares are length-gated, so a shorter subject is never
> read out of bounds.

### Break and Continue

`break` exits the innermost loop, and `continue` skips to the next iteration:

```fels
while true {
    if done() { break; }
    if skip() { continue; }
    process();
}
```

A loop can have a name, written before it with a colon. `break name;` leaves that loop, and
`continue name;` goes on with its next iteration, however many loops are in between:

```fels
outer: for i in 0..rows {
    for j in 0..cols {
        if grid[i][j] == target {
            found = .{ i, j };
            break outer;            // leaves both loops
        }
        if grid[i][j] < 0 { continue outer; }   // the next row
    }
}
```

The `defer`s of the loops being left run on the way out, as with a plain `break`. A name has to
belong to a loop around the `break` or `continue`, and a loop inside one may not take the same
name. Loops one after the other may.

### Defer

`defer` schedules code to run when the current scope exits. That guarantees the cleanup no
matter how the scope is exited (normal return, error, break, etc.):

```fels
// Always defer
defer { cleanup(); }

// Single expression defer
defer close(handle);

// Defer only on success
defer.ok { commit(); }

// Defer only on error
defer.err { rollback(); }
```

> [!NOTE]
> Multiple defers execute in **reverse order** (LIFO), so the last defer registered runs
> first.

```fels
// Example: LIFO order
defer { println("first registered, last to run"); }
defer { println("second registered, first to run"); }
// Output on scope exit:
//   second registered, first to run
//   first registered, last to run
```

### Unsafe Blocks

An `unsafe` block disables certain safety checks. You need one for raw pointer operations,
inline assembly and other low-level operations:

```fels
unsafe {
    raw_ptr := 0x1000 as *u8;
    *raw_ptr = 0;
}

// Unsafe expression
val := unsafe core::unaligned_read(u64, &x);
```

As a statement, `unsafe` must be followed by a block, so `unsafe (p as *u8);` on a line of
its own is an error. The expression form is for places where the value is used, such as an
initializer, an argument or an assignment.

> [!CAUTION]
> Unsafe code bypasses the compiler's safety guarantees, so use it sparingly and audit it
> carefully. Incorrect unsafe code can cause undefined behavior, memory corruption, or
> security vulnerabilities.

### Compile-time Directives

Fels supports compile-time evaluation through a few special directives:

```fels
// Compile-time if
#if core::sizeof(usize) == 8 {
    // 64-bit platform code
} else {
    // 32-bit platform code
}

// Compile-time expression
size := #run compute_size();
```

| Directive | Purpose                                                        |
|-----------|----------------------------------------------------------------|
| `#if`     | Conditional compilation based on compile-time constants        |
| `#run`    | Evaluate an expression at compile time (see 08) |

`#if` takes an optional `else { }`, and `else #if cond { }` for the next test of a chain. In
a function body it chooses code. At the top level it chooses declarations, by the platform
the program is built for (see [docs/08](08_attributes_builtins.md)).

### Zone Blocks

Zone blocks give you scoped memory management. The [Memory & Zones](05_memory_zones.md)
chapter has the full details:

```fels
zone scratch: Arena {
    buf := scratch.new_slice(u8, 64);
    // arena freed at end of zone
}
```

# Error Handling

Fels handles errors explicitly, with a model inspired by Zig and Rust. A function
that can fail says so in its signature, and every caller has to deal with the
possibility of failure. There are no hidden exceptions.

## Error Types

You declare an error type with the `errors` keyword. Each variant is a named
error condition, and it can carry a payload:

```fels
IoError :: errors {
    not_found,
    permission_denied,
    timeout,
}

ParseError :: errors {
    invalid_input,
    overflow: i64,         // error with payload
    buffer_full,
}
```

You refer to an error variant with a dot prefix, as in `.not_found` or `.overflow`.

## Fallible Functions

A function that can fail puts `!` and the error type after its return type:

```fels
// Named error type
read_file :: fn(path: []const u8) -> []u8 ! IoError {
    // ...
    if path.len == 0 { fail .not_found; }
    // ...
}

// Inline error set (each variant is written with a leading dot)
parse :: fn(s: []const u8) -> i32 ! { invalid, overflow } {
    // ...
}

// Inferred error type (bare `!`)
combine :: fn() -> i32 ! {
    // ...
}
```

Internally, the return type of a fallible function is a *fallible type* `T ! E`.
It is a tagged union of the success value (`T`) and the error (`E`).

A fallible function with a value (`-> i32 ! E`) must `return` or `fail` on every
path. A `-> void ! E` function may also run to the end of its body. That counts as
success, the same as `return;`:

```fels
check :: fn(n: i32) -> void ! ParseError {
    if n < 0 { fail .invalid_input; }
}
```

## The `fail` Statement

Use `fail` to return an error from a fallible function:

```fels
validate :: fn(input: []const u8) -> bool ! ParseError {
    if input.len == 0 {
        fail .invalid_input;
    }
    if input.len > 1000 {
        fail .overflow(input.len as i64);  // with payload
    }
    return true;
}
```

`fail .variant` is only allowed inside a function with a `!` error return type.
The variant must exist in the function's declared error type, and any payload
must match the payload type the variant declares. The payload goes in parentheses, as it
does for an enum variant (`Shape.circle(r)`). The older `fail .overflow { n }` still
compiles, but with a warning.

## Error Propagation with `?`

The `?` operator passes an error up to the caller, much like Rust's `?` or Zig's `try`:

```fels
outer :: fn() -> i32 ! IoError {
    data := read_file("config.txt")?;   // on error, immediately returns the error
    return process(data)?;
}
```

You can only use `?` inside a function whose error type is compatible with the
expression's error type. When the expression succeeds, `?` unwraps it and gives
you the success value.

### Chaining `?`

```fels
pub writer_append :: fn(self: *Byte_Writer, values: []const u8) -> usize ! String_Error {
    i := 0usize;
    while i < values.len {
        self.writer_put(values[i])?;   // propagate on error
        i += 1usize;
    }
    return values.len;
}
```

### Tail-forwarding a fallible result

Sometimes a function's whole job is to delegate to another fallible function with a
compatible error type. Then `return inner();` forwards the entire `{ok, err}` result,
and you need no `?`. On success it returns the ok value, and on failure the error flows
out unchanged:

```fels
connect :: fn(sa: SocketAddr) -> TcpStream ! NetError {
    return tcp::connect(sa);     // forwards ok or error, both
}
```

This is the value-returning twin of `?`. Where `?` *unwraps* and hands the ok value
to the current function, a tail-`return` *passes the result through*.

### Qualified error types

A `!` error type may be qualified with the module it comes from, like any other
type:

```fels
#import std.heap as heap;
build :: fn(into: *heap::Arena, n: usize) -> []u8 ! heap::MemError {
    return into.try_alloc_bytes(n);
}
```

## Catching Errors with `catch`

Use `catch` when you want to handle an error locally instead of passing it on:

```fels
result := parse("42") catch err {
    // `err` is bound to the error value
    println("parse failed");
    return -1;
};
// `result` holds the success value
```

The `catch` block receives the error value, bound to the name you give it. When the call has a
value (`result := parse("42") catch err { … }`), the block has to give the expression one. Either
`yield` ends the handler with the value to use in place of the call's, or the block leaves the
expression with `return`, `fail`, `break` or `continue`. In that position, a handler that can run
to its end is a compile error:

```fels
count := parse(text) catch err {
    log_error(err);
    yield 0;            // `count` is 0 when parse fails
};
```

`yield` belongs to the innermost `catch` handler. It leaves the loops inside the handler and runs
the handler's `defer`s. Its value is checked against the call's success type, the way a `return`
value is checked against the function's return type. A `yield` is refused outside a handler and in
a `defer` body. If your fallback does not look at the error, `value ?? default` (below) is shorter.

When the `catch` is a statement of its own, or the call returns `void`, there is no value to
produce, and a `yield` there is refused. The handler may then run to its end, and execution
carries on after the `catch`:

```fels
write_all(data) catch err { failures += 1; };     // ignore the byte count; count the failure and go on
```

### Errors are values

An error is a value of its set's type. You can keep it in a local, pass it to a function, store it
in a struct field or return it. Where its set's type is expected, a bare `.variant` is such a value:

```fels
last_error: ParseError = .invalid_input;

describe_kind :: fn(e: ParseError) -> []const u8 {
    if e == .buffer_full { return "buffer full"; }
    return "bad input";
}
```

`ParseError.buffer_full` and `ParseError.overflow(n)` build one, the way `Shape.circle(r)` builds
an enum value. Where the set is known, `.overflow(n)` does the same (`e: ParseError = .overflow(n)`,
or `return .overflow(n);` from `-> ParseError`).

`fail e;` raises any error value, wherever it comes from: one that a `catch` bound, a parameter,
a local or a field. The function's error set has to take that error, by the same rule as `?`.
Within one set the error goes on whole, payload and all:

```fels
retry :: fn(text: []const u8) -> i32 ! ParseError {
    return parse(text) catch err {
        if err == .buffer_full { yield parse_slowly(text)?; }
        fail err;                // anything else goes to the caller as it is
    };
}
```

### Inspecting the error variant

`err == .variant` and `err != .variant` ask whether an error is that variant. They work wherever
the error is: the name a `catch` bound, a parameter, a field or a call's result.

```fels
result := parse_json_string(input, output) catch err {
    if err == .buffer_full { return 30; }
    if err == .unexpected_end { return 31; }
    if err == .invalid_escape { return 32; }
    if err == .invalid_unicode { return 33; }
    return 35;
};
```

The variant must be one of the error's own set, so naming a variant the set does not have
(`.secnd`) is a compile error. An inferred set (bare `!`) has no list to check against, so any
name is accepted there. An error is identified by its variant's name. It keeps that name while
`?` passes it on through any number of functions, inferred sets included. A `.timeout` raised by
a function returning `IoError` is still `.timeout` when you catch it from an inferred-set
function that called it.

`match` takes an error too, either as a statement or as a value:

```fels
code := parse(text) catch err {
    yield match err {
        .invalid_input => 1,
        .overflow => 2,
        .buffer_full => 3,
    };
};
```

A match on an error of a declared or inline set covers each of its variants or has an `else`
arm, as a match on an enum does. An error of an inferred set can be any error, so a match on it
takes any variant name and always needs an `else`. Two errors of a set without payloads can be
compared with `==`. An error cannot be cast to an integer.

### Reading a payload

A variant declared with a payload (`overflow: i64`) carries a value of that type, which you give
with `fail .overflow(n)`. A `match` arm binds it, and so does `if err == .variant |name|`:

```fels
describe :: fn(e: ParseError) -> i64 {
    return match e {
        .invalid_input => 0,
        .overflow |n| => n,
        .buffer_full => -1,
    };
}

v := parse(text) catch err {
    if err == .overflow |n| { println("too big"); }
    yield 0;
};
```

The binding has the variant's payload type, and binding a variant that carries none is a compile
error. The payload goes wherever the error goes. `?` passes it on within one set, and it stays
with an error kept in a local, a field or a global. There are three limits:

- An inferred set (`-> T !`) keeps an error's variant but not its payload, so you cannot bind a
  payload through one. Give the function the named set (`-> T ! ParseError`) to pass payloads on.
- An inline set (`-> T ! { a, b }`, named as a declared set's errors are) carries no payloads. A
  variant with a payload belongs to a declared set.
- Two errors of a set with payloads do not compare with `==`, because it would not be clear
  whether that means the same variant or the same payload too. Compare each one with a variant,
  or `match` it.

## Force Unwrap with `!!`

The `!!` operator unwraps a fallible (or optional) value. If the value contains an
error (or null), it panics at runtime:

```fels
// Panics with a runtime error if parse() fails
value := parse("42")!!;

// Panics if the optional is null
ptr := maybe_ptr!!;
```

Use `!!` sparingly. It is a convenience for the cases where failure is truly
unexpected and should abort the program.

## Nil Coalesce with `??`

The `??` operator gives you a default value when the left side is an error or
null:

```fels
// Returns 0 if parse fails
value := parse("?") ?? 0;

// Returns a default for optionals too
name := get_name() ?? "unknown";
```

## Defer Modes

Besides the plain `defer`, Fels has conditional defers that run only on success or only on
failure:

```fels
process :: fn() -> void ! IoError {
    handle := open_file("data.txt")?;

    // Always runs (success or failure)
    defer close(handle);

    // Only on successful return
    defer.ok {
        commit();
    }

    // Only on error path (fail or ?)
    defer.err {
        rollback();
    }

    write(handle, data)?;
}
```

| Defer Mode | Syntax | When it runs |
|------------|--------|--------------|
| Always | `defer { ... }` | On any scope exit |
| Success only | `defer.ok { ... }` | Only on normal return |
| Error only | `defer.err { ... }` | Only on `fail` or `?` propagation |

When there are several defers, they run in reverse order (LIFO), as in Go and Zig.

`?` leaves the function the way `fail` does, so `?` runs everything that `fail` runs. That means the
defers registered before it, `defer.err`, and the exit of every `zone` it leaves. (A `defer`
placed after the `?` does not exist yet.) It works the same in code the compiler runs (`#run`,
`#assert`).

## Pattern: Fallible Function with Cleanup

A common pattern in Fels brings `defer`, `fail` and `?` together:

```fels
#import std.fs.{ FsError, open, close };
#import std.io.{ Reader, eprintln, print_u64 };

process_file :: fn(path: []const u8) -> usize ! FsError {
    file := open(path)?;
    defer close(&file);

    r: *Reader = &file;
    buf: [1024]u8 = .{};
    n := r.read(buf[:]) catch err { fail .read_failed; };
    return n;
}

main :: fn() -> i32 {
    result := process_file("data.txt") catch err {
        if err == .not_found {
            eprintln("file not found");
        }
        return 1;
    };
    print_u64(result as u64);
    return 0;
}
```

## Fallible Entry Points

`main` can be a fallible function too:

```fels
#import std.io.{ IoError, println };

main :: fn() -> i32 ! IoError {
    println("hello")?;
    return 0;
}
```

When an error propagates all the way to the top level, the runtime aborts with the
error message.

## Summary Table

| Syntax | Meaning |
|--------|---------|
| `-> T ! E` | Function returns `T` on success, `E` on error |
| `fail .variant` | Return an error |
| `fail .variant(payload)` | Return an error with payload |
| `fail err;` | Return an error value (a caught one, a parameter) |
| `ParseError.overflow(n)` | An error value, built like an enum value (`.overflow(n)` where the set is known) |
| `expr?` | Propagate error, unwrap success |
| `expr catch err { ... }` | Handle error locally |
| `yield value;` | End a `catch` handler with the value of the expression |
| `err == .variant` | Is the error that variant (anywhere) |
| `match err { .variant => ... }` | Branch on the error's variant |
| `.variant \|p\| => ...` / `if err == .variant \|p\|` | Bind the variant's payload |
| `expr!!` | Force unwrap (panic on error) |
| `expr ?? default` | Use default on error |
| `defer { ... }` | Always-run cleanup |
| `defer.ok { ... }` | Cleanup on success only |
| `defer.err { ... }` | Cleanup on error only |

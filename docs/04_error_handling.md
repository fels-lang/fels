# Error Handling

Fels uses an explicit error-handling model inspired by Zig and Rust. Functions
that can fail declare it in their signature, and callers must always handle
the possibility of failure — there are no hidden exceptions.

## Error Types

Error types are declared with the `errors` keyword. Each variant is a named
error condition, optionally carrying a payload:

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

Error variants are referenced with a dot prefix: `.not_found`, `.overflow`, etc.

## Fallible Functions

A function that can fail annotates its return type with `!` followed by the
error type:

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

The return type of a fallible function is internally a *fallible type*
`T ! E` — a tagged union of the success value (`T`) and the error (`E`).

A fallible function with a value (`-> i32 ! E`) must `return` or `fail` on every
path. A `-> void ! E` function may also run to the end of its body, which is
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

`fail .variant` is only allowed inside functions with a `!` error return type.
The variant must exist in the function's declared error type, and any payload
must match the variant's declared payload type. The payload goes in parentheses, as an
enum variant's does (`Shape.circle(r)`); the older `fail .overflow { n }` still compiles,
with a warning.

## Error Propagation with `?`

The `?` operator propagates errors upward to the caller, similar to Rust's `?`
or Zig's `try`:

```fels
outer :: fn() -> i32 ! IoError {
    data := read_file("config.txt")?;   // on error, immediately returns the error
    return process(data)?;
}
```

`?` is only valid inside a function whose error type is compatible with the
expression's error type. If the expression succeeds, `?` unwraps and yields
the success value.

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

When a function's whole job is to delegate to another fallible function with a
compatible error type, `return inner();` forwards the entire `{ok, err}` result —
no `?` needed. On success it returns the ok value; on failure the error flows out
unchanged:

```fels
connect :: fn(sa: SocketAddr) -> TcpStream ! NetError {
    return tcp::connect(sa);     // forwards ok or error, both
}
```

This is the value-returning twin of `?`: `?` *unwraps* (yielding the ok value to
the current function), while a tail-`return` *passes the result through*.

### Qualified error types

A `!` error type may be qualified with the module it comes from, just like any
other type:

```fels
#import std.heap as heap;
build :: fn(into: *heap::Arena, n: usize) -> []u8 ! heap::MemError {
    return into.try_alloc_bytes(n);
}
```

## Catching Errors with `catch`

Use `catch` to handle an error locally instead of propagating it:

```fels
result := parse("42") catch err {
    // `err` is bound to the error value
    println("parse failed");
    return -1;
};
// `result` holds the success value
```

The `catch` block receives the error value bound to the name you provide. When the call has a
value (`result := parse("42") catch err { … }`), the block gives the expression one: `yield` ends
the handler with the value to use in place of the call's, or the block leaves the expression with
`return`, `fail`, `break` or `continue`. A handler that can run to its end is a compile error
there:

```fels
count := parse(text) catch err {
    log_error(err);
    yield 0;            // `count` is 0 when parse fails
};
```

`yield` belongs to the innermost `catch` handler. It leaves the loops inside the handler, runs the
handler's `defer`s, and its value is checked against the call's success type, as a `return` value
is against the function's return type. It is refused outside a handler and in a `defer` body. For
a fallback that does not look at the error, `value ?? default` (below) is shorter.

When the `catch` is a statement of its own, or the call returns `void`, there is no value to
produce (a `yield` there is refused) and the handler may simply end; execution then carries on
after the `catch`:

```fels
write_all(data) catch err { failures += 1; };     // ignore the byte count; count the failure and go on
```

### Errors are values

An error is a value of its set's type. It can be kept in a local, passed to a function, stored in
a struct field or returned, and a bare `.variant` is one where its set's type is expected:

```fels
last_error: ParseError = .invalid_input;

describe_kind :: fn(e: ParseError) -> []const u8 {
    if e == .buffer_full { return "buffer full"; }
    return "bad input";
}
```

`ParseError.buffer_full` and `ParseError.overflow(n)` build one, as `Shape.circle(r)` builds
an enum value, and where the set is known `.overflow(n)` does (`e: ParseError = .overflow(n)`,
`return .overflow(n);` from `-> ParseError`). `fail e;` raises an error value: one a `catch` bound, a parameter, any error
the function's set takes (the rule of `?`). Within one set it goes on whole, payload and all:

```fels
retry :: fn(text: []const u8) -> i32 ! ParseError {
    return parse(text) catch err {
        if err == .buffer_full { yield parse_slowly(text)?; }
        fail err;                // anything else goes to the caller as it is
    };
}
```

### Inspecting the error variant

`err == .variant` and `err != .variant` ask whether an error is that variant, wherever the error
is: the name a `catch` bound, a parameter, a field, a call's result.

```fels
result := parse_json_string(input, output) catch err {
    if err == .buffer_full { return 30; }
    if err == .unexpected_end { return 31; }
    if err == .invalid_escape { return 32; }
    if err == .invalid_unicode { return 33; }
    return 35;
};
```

The variant must be one of the error's own set: naming a variant the set does not have (`.secnd`)
is a compile error. An inferred set (bare `!`) has no list to check against, so any name is
accepted there. An error is identified by its variant's name and keeps it as `?` passes it on
through any number of functions, inferred sets included: a `.timeout` raised by a function
returning `IoError` is still `.timeout` when it is caught from an inferred-set function that
called it.

`match` takes an error too, as a statement or as a value:

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
takes any variant name and always needs an `else`. Two errors of a set without payloads compare
with `==`. An error cannot be cast to an integer.

### Reading a payload

A variant declared with a payload (`overflow: i64`) carries a value of that type, given with
`fail .overflow(n)`. A `match` arm binds it, and so does `if err == .variant |name|`:

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

The binding has the variant's payload type; binding a variant that carries none is a compile
error. The payload goes where the error goes: `?` passes it on within one set, and it stays with
an error kept in a local, a field or a global. Three limits:

- An inferred set (`-> T !`) keeps an error's variant but not its payload, so a payload cannot be
  bound through one: give the function the named set (`-> T ! ParseError`) to pass payloads on.
- An inline set (`-> T ! { a, b }`, named as a declared set's errors are) carries no payloads; a variant with one belongs to a
  declared set.
- Two errors of a set with payloads do not compare with `==` (the same variant, or the same
  payload too?): compare each with a variant, or `match` it.

## Force Unwrap with `!!`

The `!!` operator unwraps a fallible (or optional) value, panicking at runtime
if it contains an error (or null):

```fels
// Panics with a runtime error if parse() fails
value := parse("42")!!;

// Panics if the optional is null
ptr := maybe_ptr!!;
```

Use `!!` sparingly — it is a convenience for cases where failure is truly
unexpected and should abort the program.

## Nil Coalesce with `??`

The `??` operator provides a default value when the left side is an error or
null:

```fels
// Returns 0 if parse fails
value := parse("?") ?? 0;

// Returns a default for optionals too
name := get_name() ?? "unknown";
```

## Defer Modes

Fels supports conditional defers that run only on success or failure:

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

Multiple defers execute in reverse order (LIFO), just like Go and Zig.

`?` leaves the function the way `fail` does, so everything `fail` runs, `?` runs: the defers
registered before it (a `defer` placed after the `?` does not exist yet), `defer.err`, and the
exit of every `zone` it leaves. It works the same in code the compiler runs (`#run`, `#assert`).

## Pattern: Fallible Function with Cleanup

A common pattern in Fels combines `defer`, `fail`, and `?`:

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

`main` can itself be a fallible function:

```fels
#import std.io.{ IoError, println };

main :: fn() -> i32 ! IoError {
    println("hello")?;
    return 0;
}
```

The runtime handles top-level error propagation by aborting with the error
message.

## Summary Table

| Syntax | Meaning |
|--------|---------|
| `-> T ! E` | Function returns `T` on success, `E` on error |
| `fail .variant` | Return an error |
| `fail .variant(payload)` | Return an error with payload |
| `fail err;` | Return an error value (a caught one, a parameter) |
| `ParseError.overflow(n)` | An error value, built as an enum value is; `.overflow(n)` where the set is known |
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

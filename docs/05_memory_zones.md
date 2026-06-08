# Memory & Zones

Fels has no garbage collector and no hidden allocations. You manage memory with **zones**,
which are arenas tied to a lexical scope, and **borrowing** moves that memory between scopes
without breaking ownership.

## Zone Blocks

A zone block opens a lexical scope and creates an allocation arena that belongs to that scope.

```fels
zone scratch: Arena {
    // `scratch` is now a zone handle available in this block
    
    // Allocate a single value
    ptr := scratch.new(i32);
    *ptr = 42;
    
    // Allocate a slice
    buf := scratch.new_slice(u8, 1024);
    
    // Explicitly free an allocation (optional, arena clears automatically)
    scratch.free(ptr);
    
    // At the end of this block, the entire `scratch` arena is freed
}
```

- For now, `Arena` is the only supported zone kind.
- You cannot nest zones with the same name.
- Memory allocated in a zone lives exactly as long as the zone's block.

### The handle is a real `std.heap.Arena`

A zone handle **is** a [`std.heap.Arena`](07_stdlib.md), the same chunked bump allocator you
can construct by hand with `std.heap.make()`. Entering the zone amounts to `handle := make()`.
Every exit path (normal, `return`, `break`, `continue`, `fail`) runs `deinit()` automatically,
so the arena is always drained on the way out. You never write `make`/`deinit` yourself. The
module does not need to `#import std.heap` either, because the compiler injects it whenever a
zone block is present. A file with a zone sees its public names as `#import std.heap.*;` would
bring them in, so a name of the file's own must not be one of them (`make`, `reset`, `mark`).

Because the handle is a full `Arena`, the whole library API is available on it, not only
`new`/`new_slice`:

```fels
zone z: Arena {
    p   := z.new(i32);              // alias for alloc_one(i32)
    xs  := z.new_slice(u8, 64);     // alias for alloc(u8, 64)
    ys  := z.alloc(i32, 16);        // typed allocation
    raw := z.alloc_bytes(128);      // raw []u8
    cp  := z.dupe(u8, "hello");     // copy a slice into the arena

    m := z.mark();                  // save a watermark …
    tmp := z.alloc_bytes(4096);     // … scratch work …
    z.restore(m);                   // … then rewind it, keeping the memory
}
```

`new`/`new_slice` stay as the zone-flavored spellings of `alloc_one`/`alloc`. `free` is a
no-op that the compiler checks. A bump arena reclaims everything at once when the zone exits,
so freeing a single allocation only verifies ownership.

## Ownership and Escape Analysis

When you allocate memory in a zone, the pointer (or slice) you get back is "owned" by that
zone. Fels runs a strict escape analysis at compile time to make sure zone-allocated memory
does not outlive its arena.

```fels
escape_example :: fn() -> []u8 {
    zone local: Arena {
        buf := local.new_slice(u8, 100);
        
        // COMPILER ERROR: zone-owned value cannot be returned
        return buf; 
    }
}
```

**Ownership Rules:**
1. **Assignment propagation**: Storing a zone-owned value in a variable makes that variable
   zone-owned too.
2. **No Escape**: A zone-owned value cannot escape to an outer scope or be returned from a
   function.
3. **Restricted Passing**: A zone-owned value can only be passed as an argument to a function
   parameter that is explicitly marked with `borrow`.
4. **Valid Freeing**: You can only `free` a value through the zone handle that owns it.

The same check keeps addresses in a function's own frame from leaving it. You cannot return
the address of a local, a parameter or a temporary
(see [Pointer Types](02_types.md#single-pointers)).

## Borrow Parameters

To pass zone-allocated memory to a function, the function must declare that it borrows the
memory. It does that with the `borrow` keyword.

```fels
// The `borrow` keyword tells the compiler this slice is temporary
// and will not be stored or escape.
process_data :: fn(data: borrow []u8) {
    data[0] = 255u8;
}

main :: fn() -> i32 {
    zone scratch: Arena {
        buf := scratch.new_slice(u8, 1024);
        
        // Allowed: passing zone memory to a borrow parameter
        process_data(buf);
    }
    return 0;
}
```

**Borrowing Rules:**
1. `borrow` is only valid as the **outermost** qualifier of a function parameter. That means
   `borrow *T`, `borrow []T`, or a value that holds one: `borrow Parser` for a struct, and the
   same for an optional or an array.
2. You cannot nest `borrow` qualifiers (e.g., `borrow borrow *T` is invalid).
3. `borrow` is **not valid** on return types, local variables, struct fields, or const
   declarations.
4. **A value made from borrowed data is borrowed.** A struct or array local that holds a
   borrowed value (built with it, or with a field or element set to it) is borrowed in turn.
   You can read it, change it and pass it to a `borrow` parameter, but you cannot return it or
   pass it on to a parameter that does not borrow. A borrowed value cannot be stored through a
   pointer or into a global, because either would outlive the borrow.
5. A borrowed value cannot be freed explicitly.
6. Inside the function, a borrowed value is transparent to type-checking, so you work with it
   like a normal pointer or slice.

A parser over a borrowed buffer is a plain struct:

```fels
Parser :: struct { src: []const u8, pos: usize }

next :: fn(p: borrow *Parser) -> u8 { b := p.src[p.pos]; p.pos += 1; return b; }
peek :: fn(p: borrow Parser) -> u8 { return p.src[p.pos]; }

count_a :: fn(text: borrow []const u8) -> i32 {
    p: Parser = .{ text, 0 };          // `p` borrows `text`
    n: i32 = 0;
    while p.pos < p.src.len { if next(&p) == 'a' { n += 1; } }
    return n;                          // `return p;` would be an error
}
```

## Example: Building a Temporary String

Zones work well for temporary processing, where you would otherwise use a GC or manage
malloc/free by hand. This program builds a string in a zone buffer and then checks it:

```fels
#import std.io.{ println };

// Copies `s` into `buf` at `at` and returns the position after it.
put :: fn(buf: borrow []u8, at: usize, s: []const u8) -> usize {
    for i in 0..s.len { buf[at + i] = s[i]; }
    return at + s.len;
}

main :: fn() -> i32 {
    zone temp: Arena {
        buf := temp.new_slice(u8, 64);    // the buffer lives in the zone
        n := put(buf, 0, "Hello, ");      // a plain `buf`: `borrow` is only on the parameter
        n = put(buf, n, "zones!");
        if buf[0..n] == "Hello, zones!" { println("built it"); }
    } // the buffer is freed here
    return 0;
}
```

You write `borrow` on the parameter, never at the call. The buffer can only go to `borrow`
parameters, so `println(buf[0..n])` is a compile error, because `println` takes a plain slice.

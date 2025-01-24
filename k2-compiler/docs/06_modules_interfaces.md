# Modules, Interfaces, and Generics

## Modules

In K2, a module corresponds exactly to a file. 

### Imports

Use the `#import` directive to bring symbols from another module into scope.
Paths are dot-separated relative to the current file, or start with `std.` for the standard library.

```k2
// Selective import (recommended)
#import std.io.{ Writer, println };

// Wildcard import (imports all public symbols)
#import std.fs;

// Local import (from sibling file math.k2)
#import math.{ add, multiply };
```

### Visibility

By default, all declarations (`fn`, `struct`, `const`, etc.) are private to the module.
Use the `pub` keyword to make them accessible from other modules.

```k2
// Only usable in this file
helper :: fn() { ... }

// Usable by anyone who imports this file
pub connect :: fn() { ... }

// Public struct definition
pub User :: struct {
    id: u64,
    name: []const u8,
}
```

---

## Interfaces

Interfaces in K2 define a set of methods that a type must implement. They enable
dynamic dispatch via `*InterfaceType` pointers.

### Declaration

```k2
#import std.io.{ IoError };

pub Writer :: interface {
    write :: fn(*Self, []const u8) -> usize ! IoError;
    flush :: fn(*Self) -> void ! IoError;
}
```
Notice the `*Self` parameter. Every interface method must take `*Self` (or `borrow *Self`) as its first parameter.

### Implementation

You implement an interface for a concrete type using the `as` keyword outside of the struct definition:

```k2
File :: struct { handle: usize }

// Implementing Writer for File
File as Writer {
    write :: fn(self: *Self, data: []const u8) -> usize ! IoError {
        // Implementation here...
        return data.len;
    }
    
    flush :: fn(self: *Self) -> void ! IoError {
        // Implementation here...
    }
}
```

### Dynamic Dispatch

You can implicitly coerce a pointer to a concrete type into an interface pointer.
Calls through an interface pointer use a vtable for dynamic dispatch.

```k2
process :: fn(w: *Writer) -> !void {
    w.write("Hello")?;
}

main :: fn() {
    f := File { handle = 1 };
    
    // Implicit coercion from *File to *Writer
    process(&f) catch { return; };
}
```

### Extension Methods

Any function whose first parameter is named `self` acts as an extension method
and can be called using dot-syntax:

```k2
pub write_all :: fn(self: *Writer, data: []const u8) -> usize ! IoError {
    // ...
}

// Can be called as:
// w.write_all(data)?
```

---

## Generics

K2 provides static polymorphism via monomorphized generics. 
Each unique combination of type arguments generates a separate, specialized copy of the function or struct.

### Generic Functions

Generic type parameters are prefixed with `$`:

```k2
// $T is an unconstrained type parameter
identity :: fn(value: $T) -> T {
    return value;
}

// $T is inferred from the argument
main :: fn() {
    a := identity(42i32);  // T becomes i32
    b := identity(true);   // T becomes bool
}
```

You can also pass types explicitly as arguments:

```k2
max :: fn($T: type, a: T, b: T) -> T {
    if a > b { return a; }
    return b;
}

// Call with explicit type
result := max(i32, 10, 20);
```

### Constrained Generics

You can constrain a type parameter to types that implement a specific interface:

```k2
// $W must be a type that implements the Writer interface
print_to :: fn($W: Writer, writer: *W, data: []const u8) -> usize ! IoError {
    // Statically dispatched call! No vtable lookup overhead.
    return writer.write(data)?;
}
```

### Generic Structs

```k2
Pair :: struct($T: type, $U: type) {
    first: T,
    second: U,
}

p: Pair(i32, bool) = .{ 42, true };
```

# Modules, Interfaces, and Generics

## Modules

In Fels, a module corresponds exactly to a file. Every file is a module, and every module is
one file.

### Imports

The `#import` directive brings another module's public symbols into scope. A path is a list
of names separated by dots. It is relative to the current file. A path into the standard
library starts with `std.`, and a path into a package starts with the package's name (see
[Packages](16_packages.md)). You can import in four forms:

```fels
// 1. Namespace import: bind the module under its last path segment.
//    Members are reached with `::`; the module's names are NOT pulled into scope.
#import std.io;
... io::println("hi");   io::Writer ...

// 2. Aliased namespace: choose the namespace name yourself.
#import std.io as term;
... term::println("hi");

// 3. Selective: bring just the listed names in unqualified.
#import std.io.{ Writer, println };
... println("hi");

// 4. Glob: bring every public name in unqualified.
#import std.io.*;
... println("hi");

// Local modules work the same (sibling file math.fels):
#import math;            math::add(1, 2);
#import math.{ add };    add(1, 2);
```

**`::` vs `.`**: `::` reaches a member of a *module namespace* (`io::println`), and `.`
reaches a *value's* field or method (`point.x`, `writer.flush()`). Because the two stay
distinct, a local variable named `io` never shadows the `io` namespace.

> **Collisions are fine.** Two different modules may each declare the same name, for
> example when both define a `greet` or a `parse`. The compiler mangles colliding names per
> module internally, so they link cleanly. You reach each one through its namespace
> (`a::greet`, `b::greet`) or through a selective or glob import. A name is only mangled
> when it actually collides, and unique names keep their bare linkage. This holds for
> functions, constants and types alike. A file that imports `std.io` may declare its own
> `Writer`, and `io::Writer` is still the other one. What you cannot do is import the name
> itself next to your own (`#import std.io.{ Writer };`). That is ambiguous, and it is an
> error.

### Visibility

By default, every declaration (`fn`, `struct`, `const`, etc.) is private to its module.
Put the `pub` keyword in front of one to make it accessible from other modules.

```fels
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

A module can offer another module's type under its own name. You write a `pub` alias of the
type, with the same name or a different one, and that is a re-export. Importers then name
the type, build it and call its associated functions through your module. An error set
re-exported this way can stand after `!` as well:

```fels
// shapes/circle.fels
pub Circle :: struct { r: f64
    pub unit :: fn() -> Circle { return .{ 1.0 }; }
}

// shapes.fels
#import shapes.circle as circle;
pub Circle :: circle::Circle;        // the same type, offered by `shapes`

// main.fels
#import shapes;
c: shapes::Circle = shapes::Circle::unit();
```

`std.net` does this for the types of its submodules (`net::TcpStream`, `net::NetError`). You
re-export a function the same way, with a `pub` constant that names it. After
`pub read :: files::read_all;`, calling `module::read(…)` calls that function.

## Interfaces

An interface in Fels names a set of methods that a type must implement. Through
`*InterfaceType` pointers, interfaces give you dynamic dispatch.

### Declaration

This is how `std.io` declares its `Writer` interface:

```fels
pub Writer :: interface {
    write :: fn(self: *Self, data: []const u8) -> usize ! IoError;
    flush :: fn(self: *Self) -> void ! IoError;
}
```
Notice the `self: *Self` parameter. Every interface method must take `*Self` (or
`borrow *Self`) as its first parameter. Every parameter has a name, as in any function
declaration.

### Implementation

You implement an interface for a concrete type with the `as` keyword, outside of the struct
definition:

```fels
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

A pointer to a concrete type coerces implicitly into an interface pointer. Calls through an
interface pointer then use a vtable, so the method is chosen at run time (dynamic dispatch).

With the `Writer` and `File` above:

```fels
process :: fn(w: *Writer) -> void ! IoError {
    w.write("Hello")?;
}

use_file :: fn() {
    f: File = .{ .handle = 1 };

    // Implicit coercion from *File to *Writer
    process(&f) catch err { return; };
}
```

### Extension Methods

Any function whose first parameter is named `self` acts as an extension method, so you can
call it with dot syntax:

```fels
pub write_all :: fn(self: *Writer, data: []const u8) -> usize ! IoError {
    // ...
}

// Can be called as:
// w.write_all(data)?
```

A type's *own* methods can instead be declared **inside the struct body**, where `Self` and
the struct's type parameters are implicit (see [Methods](02_types.md#methods)). Use in-struct
declarations for a type's own API, and free `self`-first functions to extend a type you
don't own. When you call a method on that type, an in-struct method shadows a free function
of the same name.

## Generics

Fels gives you static polymorphism through monomorphized generics. Each unique combination
of type arguments generates a separate, specialized copy of the function or struct.

### Generic Functions

You mark a generic type parameter with a `$` in front of its name:

```fels
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

```fels
max :: fn($T: type, a: T, b: T) -> T {
    if a > b { return a; }
    return b;
}

// Call with explicit type
result := max(i32, 10, 20);
```

### Constrained Generics

You can constrain a type parameter to types that implement a specific interface:

```fels
// $W must be a type that implements the Writer interface
print_to :: fn($W: Writer, writer: *W, data: []const u8) -> usize ! IoError {
    // Statically dispatched call! No vtable lookup overhead.
    return writer.write(data)?;
}
```

### Generic Structs

```fels
Pair :: struct($T: type, $U: type) {
    first: T,
    second: U,
}

p: Pair(i32, bool) = .{ 42, true };
```

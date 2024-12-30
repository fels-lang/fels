todo:

align()

attrivutes,
etc...


zones,
meta programming, generic

generic structs?

@panic / assert

build driver, installer / comptime exectution,
etc...
synatx is very sexy :D .dD :D:D:D:D


Let me go through each systematically with a clear K2 design decision for each.

---

## Bitstructs — K2 alternative: sub-byte integers

C3's `bitstruct` is specialized syntax for bit-packed hardware registers:
```c3
bitstruct ControlReg : char @bigendian {
    bool enable   : 0;
    int  mode     : 1..3;
    bool flag     : 7;
}
```

**K2's answer: `u1`, `u2`, `u3`, `u4`, `u5`, `u6`, `u7` in `#packed` structs**

No special syntax needed — sub-byte integers in packed structs give you the same thing, more composably:

```k2
#packed
ControlReg :: struct {
    enable:   u1,
    mode:     u3,
    reserved: u3,
    flag:     u1,
}   // = exactly 1 byte

// Usage identical to normal struct:
reg.enable = 1;
reg.mode = 5;

// And you can still do it manually if you need endian control:
raw := unsafe unaligned_read(u8, mmio_ptr);
enable := (raw >> 0) & 0x01;
mode   := (raw >> 1) & 0x07;
```

**Decision: add `u1`–`u7` and `i1`–`i7` as sub-byte integers. Skip `bitstruct`.**

`#bigendian` / `#littleendian` can be added as struct attributes for protocol headers when needed.

---

## Vectors (SIMD) — planned, deferred

C3: `int[<4>]`, `float[<8>]` — hardware SIMD types with arithmetic ops

**K2 plan:** Same syntax `[<N>]T` (consistent with array `[N]T`). Deferred until codegen is solid.

```k2
// Future K2 SIMD:
v1: [<4>]f32 = .{ 1.0, 2.0, 3.0, 4.0 };
v2: [<4>]f32 = .{ 5.0, 6.0, 7.0, 8.0 };
v3 := v1 + v2;   // parallel add → .{ 6, 8, 10, 12 }

// Swizzle (future)
xy := v1.xy;     // [<2>]f32 = .{ 1.0, 2.0 }
```

Currently: use inline asm for SIMD. Not a blocker.

---

## Contracts — lighter K2 version

C3 contracts (`@require`/`@ensure`) are Design by Contract from Eiffel — preconditions, postconditions, invariants. They're checked in debug mode, stripped in release.

**Do we need them?** Yes — they're basically typed debug assertions. K2 already has the concept partially via `assert` (coming). Contracts are `assert` at function boundaries.

**K2 design** — use `#require` and `#ensure`, consistent with K2's `#` syntax:

```k2
// #require: precondition — checked on entry in debug mode
sqrt :: fn(x: f64) -> f64
    #require(x >= 0.0, "sqrt of negative number")
{
    return raw_sqrt(x);
}

// #ensure: postcondition — checked on exit in debug mode
sort :: fn(arr: []i32) -> []i32
    #ensure(arr.len == return.len, "sort must not change length")
{
    // ...
}

// Both strip to nothing in release mode
// Both emit @panic-style errors in debug mode
```

These compile to:
- **Debug**: `assert(cond, msg)` call before/after body
- **Release**: removed entirely

Worth implementing once `@panic` exists. Small parser + sema change.

---

## Attributes — K2 vs C3 full comparison

C3 uses `@attr` on the right. K2 uses `#attr` on the left. Both work; K2's `#` is consistent with `#run`, `#if`, `#import`.

### What K2 has today

| K2 | C3 equivalent | Status |
|----|--------------|--------|
| `#extern("lib","sym")` | `@cname` + `@export` | ✅ |
| `#packed` | `@packed` | ✅ |
| `#align(N)` | `@align(N)` | ✅ stored, ⚠️ partially applied |
| `#inline` | `@inline` | ✅ |
| `#naked` | `@naked` | ✅ |
| `#entry` | `@winmain` / `@init` | ✅ |

### C3 attributes K2 should add (priority order)

```k2
// #noreturn — function never returns (needed for @panic)
#noreturn
panic :: fn(msg: []const u8) { sys_write(2, msg); sys_exit(1); }

// #noinline — prevent inlining
#noinline
cold_path :: fn() { ... }

// #export("sym") — expose symbol to linker under a name
#export("k2_main")
main :: fn() -> i32 { ... }

// #deprecated("use X instead") — warn on use
#deprecated("use write_stderr instead")
log_error :: fn(msg: []const u8) { ... }

// #test — mark as test function (for future test runner)
#test
test_addition :: fn() {
    assert(1 + 1 == 2);
}

// #benchmark — mark as benchmark
#benchmark
bench_sort :: fn() { ... }

// #section(".hot") — linker section placement
#section(".text.hot")
critical_loop :: fn() { ... }

// #link("opengl32") — implicitly link a library when this is used
#link("kernel32")
Sleep :: fn(ms: u32);

// #callconv("stdcall") — explicit calling convention
#callconv("stdcall")
OldWindowsApi :: fn(hwnd: usize) -> i32;

// #noalias — pointer doesn't alias others (like C's restrict)
memcpy :: fn(#noalias dst: *u8, #noalias src: *const u8, n: usize) { ... }

// #init(priority) / #fini — run at startup/shutdown
#init(256)
setup_global_state :: fn() { ... }

#fini
cleanup_global_state :: fn() { ... }
```

### C3 attributes K2 intentionally skips

| C3 attribute | K2 position |
|---|---|
| `@bigendian`/`@littleendian` | Not needed without bitstruct |
| `@overlap` | Not needed without bitstruct |
| `@compact` | `#packed` already recursive |
| `@operator` | No operator overloading by design |
| `@dynamic`/`@optional` | No interfaces yet |
| `@wasm` | Add when targeting WASM |
| `@obfuscate` | Niche, skip |
| `@pure` | Comptime handles this better |
| `@maydiscard` | K2's `_` discard is explicit |
| `@nostrip` | Use `#export` instead |
| `@nosanitize` | Add when sanitizers exist |

### User-defined attributes (K2 design)

C3 has `attrdef`. K2's equivalent should be composable:

```k2
// Bundle multiple attributes under one name
#attrdef hot = #inline, #section(".text.hot");
#attrdef cold = #noinline, #section(".text.cold");

// Use:
#hot
frequently_called :: fn() { ... }

#cold
rarely_called :: fn() { ... }
```

---

## Memory management — K2 zones vs C3 allocators

**C3 approach:** allocator-passing + temp pool

```c3
// You pass the allocator to everything
List{int} list;
list.init(mem);          // heap allocator
list.init(tmem);         // temp allocator

@pool() {
    int* a = tmalloc(int::size);   // temp allocation
};  // freed here
```

**K2 approach:** zones (lexical scopes)

```k2
// Zone is a named scope, not a parameter
zone scratch: Arena {
    data := scratch.new_slice(u8, 1024);
    node := scratch.new(TreeNode);
}  // freed here automatically

// No need to pass allocator to everything
// The zone is implicit — any allocation in scope uses it
```

**Comparison:**

| | C3 | K2 |
|--|-----|-----|
| Heap allocation | `mem::new(T)` | `zone h: GPA { h.new(T) }` |
| Temp allocation | `@pool { tmalloc(...) }` | `zone s: Arena { s.new(T) }` |
| Pass allocator | `list.init(mem)` | Not needed — zone is in scope |
| Cleanup | `list.free()` | Automatic at `}` |
| Error cleanup | Manual `if (catch)` | `defer.err { }` |
| Nested pools | `@pool { @pool { } }` | `zone a: Arena { zone b: Arena { } }` |

**K2 advantages:**
- No `list.free()` — cleanup is always automatic
- `defer.err` handles error cleanup elegantly (C3 has no equivalent)
- No need to thread allocator through every function call

**K2 missing:**
- Global heap allocator access (for non-zone code)
- Clone helpers (`@clone`, `@clone_slice`)

---

## Reflection, Any & Interfaces — roadmap

| Feature | C3 | K2 today | K2 plan |
|---------|-----|----------|---------|
| `#type_info(T)` | Full runtime | Comptime only | Comptime → runtime |
| `any` type | ✅ fat ptr + typeid | ❌ | Enum with payloads as workaround |
| Interfaces | ✅ `@dynamic` vtable | ❌ | vtable-based, explicit |
| Runtime typeid | ✅ | ❌ | When interfaces land |
| Foreach over fields | ✅ | ❌ | Via `#type_info` iteration |

**K2 interface design (planned):**
```k2
// Explicit vtable interface
Writer :: interface {
    write :: fn(self: *Self, data: []const u8) -> usize;
    flush :: fn(self: *Self);
}

// Implement for a type
impl Writer for FileHandle {
    write :: fn(self: *Self, data: []const u8) -> usize { ... }
    flush :: fn(self: *Self) { ... }
}

// Use as fat pointer
w: *Writer = &my_file;
w.write("hello\n");
```

---

## Undefined Behaviour — K2's model

K2's explicit UB contract (to document and implement):

| Situation | Debug | Release |
|-----------|-------|---------|
| Integer overflow | trap + message | wrapping (or UB) |
| Null dereference | trap | UB |
| Out-of-bounds index | trap | UB |
| Use-after-free (via zones) | detected when zone exits | UB |
| Uninitialized use | variable must be init'd | UB |
| Data race | (via atomic / unsafe) | UB |

K2 operators (planned):
```k2
x +% y   // wrapping add — always wraps, never UB
x +| y   // saturating add — clamps to max/min (future)
x + y    // checked in debug, wrapping in release
```

This is the same model as Zig. Clear, explicit, systems-appropriate.

---

## Summary — what K2 needs next

**Add soon (small):**
- `u1`–`u7` sub-byte integers (replaces bitstruct)
- `#noreturn`, `#noinline`, `#export`, `#deprecated`
- `#require`/`#ensure` contracts (once `assert` exists)
- Wrapping arithmetic operators (`+%`, `-%`, `*%`)

**Medium term:**
- `#link("libname")`, `#section(...)`, `#callconv(...)`
- User-defined attributes (`#attrdef`)
- SIMD vectors `[<N>]T`

**Long term:**
- Interfaces / vtables
- Runtime `any` type
- Full reflection

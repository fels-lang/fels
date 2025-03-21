# Standard Library

The K2 standard library (`std`) provides core functionality. It is designed to
be minimalistic and allocation-free wherever possible. 

Here are the primary modules:

## `std.io`
Synchronous, allocation-free I/O interfaces and utilities.

**Interfaces:**
- `Writer`: `write`, `flush`
- `Reader`: `read`

**Implementations & Tools:**
- `stdout()`, `stderr()`: Returns `Stdout` / `Stderr` structs that implement `Writer`.
- `fixed_buf()`: A stack-allocated 256-byte buffer implementing `Writer` (`FixedBuf`).
- `null_writer()`: A writer that discards output but counts bytes (`NullWriter`).

**Extension Methods (on `*Writer`):**
- `write_all`, `write_line`, `write_char`, `write_repeat`
- `write_bool`, `write_u64`, `write_i64`, `write_hex_u64`

**Free functions for console:**
- `print(data)`, `println(data)`, `print_u64(val)`, `eprintln(data)`

---

## `std.fmt`
Formatting utilities built on top of `std.io.Writer`.

- `write_padded_left`, `write_padded_right`, `write_padded_center`
- `write_u64_padded`, `write_hex_u64_padded`
- `join_bytes(w: *Writer, items: []const []const u8, sep: []const u8)`

---

## `std.mem`
Safe typed-memory generic helpers.

- `eql($T: type, a: []const T, b: []const T) -> bool`
- `starts_with`, `ends_with`, `contains`, `index_of`
- `copy($T: type, dest: []T, src: []const T)`
- `fill($T: type, slice: []T, value: T)`
- `swap`, `reverse`

Byte-specialized aliases are provided: `eql_bytes`, `copy_bytes`, `zero`.

---

## `std.fs`
Minimal synchronous file I/O (Windows-only currently).

- `open(path)`: Open existing file for reading
- `create(path)`: Create/truncate file for writing
- `append(path)`: Open for appending
- `delete(path)`: Remove a file
- `exists(path)`: Check file existence
- Returns a `File` struct which implements both `Reader` and `Writer`.

---

## `std.process`
Process management (Windows-only currently).

- `spawn(cmd)`: Spawn a child process (returns `Child`)
- `wait(child)`, `try_wait(child)`, `kill(child)`, `release(child)`
- `current_pid()`
- `get_env`, `set_env`, `unset_env`
- `command_line`

---

## `std.ptr`
Pointer manipulation and conversions (requires `unsafe` in some contexts).

- `to_addr(p: *T) -> usize`
- `from_addr($T: type, addr: usize) -> *T`
- `add_bytes`, `sub_bytes`, `diff_bytes`
- `is_aligned`, `align_down`, `align_up`
- `is_null`

---

## `std.bits`
Bit-twiddling utilities.

- `count_ones_u32`, `count_ones_u64`
- `leading_zeros_u32`, `trailing_zeros_u64`, etc.
- `rotate_left_u32`, `rotate_right_u64`, etc.
- `is_power_of_two_u32`
- `bit_u32`, `set_bit_u32`, `clear_bit_u32`, `toggle_bit_u32`

---

## `std.atomics`
Atomic loads and spin-waiting. Operates on `*atomic u32` pointers.

- `load(flag)`
- `is_set(flag)`
- `wait_until_set(flag)`
- `wait_until_eq(flag, value)`

## Game & graphics modules

Small, focused modules for 2D games and graphics. `std.math` and `std.color` are
self-contained (no libm); `std.rand` is a deterministic PRNG.

### `std.math`

Vectors (`f32`), rectangles, and scalar helpers. Component math wraps the `core::`
math builtins; `sin`/`cos`/`tan` use a fast polynomial (no libm dependency).

- **Scalars:** `lerp`, `approach`, `signf`, `deg2rad`, `rad2deg`, `wrapf`, `sin`, `cos`, `tan`. Constants `PI`, `TAU`, `DEG2RAD`, `RAD2DEG`.
- **`Vec2`:** `v2`, `v2_zero`, `v2_splat`, `v2_add/sub/mul/scale/neg`, `v2_dot`, `v2_len`, `v2_len2`, `v2_dist`, `v2_dist2`, `v2_normalize`, `v2_lerp`, `v2_perp`, `v2_rotate`, `v2_from_angle`.
- **`Vec3`:** `v3`, `v3_add/sub/scale`, `v3_dot`, `v3_cross`, `v3_len`, `v3_normalize`.
- **`Rect`:** `rect`, `rect_contains`, `rect_overlaps` (AABB), `rect_center`.

### `std.rand`

Deterministic xorshift64\* PRNG — same seed, same sequence (replays, procedural gen).

- `seed(u64) -> Rng`, `next_u64`, `next_u32`, `next_f32` (\[0,1)), `range_i32(lo,hi)`, `range_f32(lo,hi)`, `chance(p)`, `sign()`.

### `std.color`

32-bit RGBA color.

- `rgb`, `rgba`, `with_alpha`, `gray`, named colors (`white`/`black`/`red`/`green`/`blue`/`yellow`/`orange`/`purple`/`clear`), `lerp`, `to_u32`/`from_u32` (0xRRGGBBAA).

### `std.list`

A generic `List(T)` dynamic array backed by an `Arena` — the intended collection
type for entities/projectiles. The arena owns every element; there are no per-element
frees. Pass the element type explicitly to each op (`list::push(Bullet, &xs, b)`).

```k2
#import std.heap as heap;
#import std.list as list;

a  := heap::make();
xs := list::make(i32, &a);          // or with_cap(i32, &a, n)
list::push(i32, &xs, 7);            // grows ×2 when full
v  := list::get(i32, &xs, 0usize);
list::set(i32, &xs, 0usize, 9);
list::remove_swap(i32, &xs, i);     // O(1) unordered removal
last := list::pop(i32, &xs);
for_each := list::items(i32, &xs);  // []T view, valid until the next push/grow
```

- Constructors: `make`, `with_cap`. Access: `get`, `set`, `last`, `items`.
- Mutation: `push`, `pop`, `remove_swap`, `clear`. Queries: `len`, `is_empty`.

> `list::make` deliberately shares the name `make` with `heap::make`; calling both
> from the same file is fine (the module system keeps them distinct).

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

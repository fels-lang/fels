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
Atomic operations over shared memory — the foundation for lock-free code and
synchronising threads. Each operation acts on a pointer to the value and **infers
the element type** (no explicit `$T`). Read-modify-write helpers return the
**previous** value, like C/LLVM. Helpers default to **sequentially consistent**
ordering; for finer control call the `core::atomic_*` builtins with an ordering
constant (`Relaxed`/`Acquire`/`Release`/`AcqRel`/`SeqCst`).

```k2
#import std.atomics;

counter: u32 = 0u32;
old := atomics::fetch_add(&counter, 1u32);          // returns the previous value
if atomics::compare_exchange(&counter, 1u32, 100u32) { /* swapped */ }
```

**Compile-time type contracts.** Each operation is guarded by a `constraint`
(`Native`/`Numeric`/`Integer`/`Boolean`) built on `core::type_info` reflection, so
misuse is a clear compile error rather than a backend failure — e.g. a bitwise op
on a float:
```
error: type `f64` does not satisfy `Integer`: bitwise/shift/min/max atomics
require an integer type
```

- **Load/store:** `load`, `store`, `load_acquire`, `store_release`
- **Read-modify-write** (return previous): `swap`, `fetch_add`/`fetch_sub` (numeric,
  float-aware), `fetch_mul`/`fetch_div` (numeric, CAS loop), `fetch_max`/`fetch_min`
  (integer), `fetch_and`/`fetch_or`/`fetch_xor`/`fetch_nand` (integer),
  `fetch_shl`/`fetch_shr` (integer, CAS loop)
- **Compare-exchange:** `compare_exchange(p, expected, desired) -> bool`,
  `compare_exchange_value` (returns the value actually seen)
- **Fences:** `fence()`, `fence_acquire()`, `fence_release()`
- **Flags / spinlock:** `is_set`, `test_and_set`, `clear`, `wait_until_set`,
  `wait_until_eq`, `spin_lock`, `spin_unlock`

### `Atomic(T)` — a typed atomic cell

The free functions act on a raw `*T`. `Atomic(T)` instead *wraps* the value, so the
type itself documents that it's shared, and the operations read as methods. The
element type is recovered from the receiver, so you never write `$T`:

```k2
#import std.atomics;
#import std.atomics.{Atomic};         // bring the type name into scope

counter: Atomic(u32) = .{ 0u32 };     // or: counter := atomics::make(0u32);
old := counter.add(1u32);             // returns the previous value
if counter.cas(1u32, 100u32) { ... }  // compare-and-swap
n := counter.get();
```

Methods: `get`/`set`, `get_acquire`/`set_release`, `exchange`, `cas`/`cas_value`,
`add`/`sub`/`mul`/`div` (numeric), `max`/`min`, `and`/`or`/`xor`/`nand` (integer) —
each carrying the same compile-time contract as its free-function counterpart.

> Atomic increments across threads lose nothing under contention — that's the whole
> point (a plain `+= 1` would race). See `tests/fixtures/stdlib/atomics_thread_app.k2`,
> and `atomic_cell_app.k2` for the `Atomic(T)` method API.

## `std.thread`
Native OS threads and structured helpers. k2 favours *real threads* over async/await
— no function colouring, no hidden executor, no heap-allocated coroutine frames; a
thread is a stack plus an entry point. An entry has the shape `fn(*void) -> u32`: it
receives a single context pointer and returns an exit code.

Because k2's ordinary function value is a fat `{fn, env}` closure that a C ABI can't
call, hand the entry over as **`core::fn_ptr(worker)`** — the raw thin function
pointer. The context pointer you pass must outlive the thread (join before its data
leaves scope, or put the data on a long-lived arena).

```k2
#import std.thread;
#import std.atomics;

worker :: fn(p: *void) -> u32 {
    c := unsafe (p as *u32);
    atomics::fetch_add(c, 1u32);
    return 0u32;                 // exit code
}

counter: u32 = 0u32;
t := thread::spawn(core::fn_ptr(worker), unsafe ((&counter) as *void));
code := t.join();                // blocks; returns the worker's exit code
```

- **`Thread`** (methods): `join() -> u32` (waits, returns exit code, closes handle),
  `detach()` (fire-and-forget), `is_running()` (non-blocking poll), `ok()`.
- **`spawn(entry, arg) -> Thread`** — start a thread; `entry` is `core::fn_ptr(fn)`.
- **Helpers:** `current_id()`, `sleep(ms)`, `yield_now()`, `cpu_count()`.
- **`ThreadGroup`** — structured fan-out: `spawn(entry, arg)` adds a thread,
  `join_all()` blocks until the whole batch finishes (the batch can't outlive the
  call site). `thread::group()` makes an empty one.

```k2
g := thread::group();
i: usize = 0usize;
while i < thread::cpu_count() as usize { g.spawn(core::fn_ptr(worker), cp); i += 1usize; }
g.join_all();                    // wait for all
```

> Thread pools and channels build on a future `std.sync` (Mutex/CondVar); for now
> coordinate with `std.atomics`. See `tests/fixtures/stdlib/thread_app.k2`.

## `std.net` and `std.net.addr`
TCP networking over Winsock2, spread across two files (a subdirectory module):
`std.net.addr` for addresses, `std.net` for sockets. It leans on the newer language
features — in-struct methods, `#derive`, and `!`-fallible returns.

**`std.net.addr`** — `IpV4` (`#derive(Eq)` + a hand-written `format` rendering a
dotted quad) and `SocketAddr` (whose derived `Eq` recurses into `IpV4.eq`):
```k2
#import std.net.addr as addr;
ip  := addr::parse("127.0.0.1") catch e { ... };   // fallible
sa  := addr::socket_addr(addr::localhost(), 8080u16);
sa.format(&sb);                                      // "127.0.0.1:8080"
```

**`std.net`** — `init()` (call once), then `dial(addr)` / `serve(addr)`:
```k2
#import std.net as net;

net::init() catch e { return; };

// client
s := net::dial(net::socket_addr(net::localhost(), 8080u16)) catch e { return; };
ignored := s.send("ping") catch e {};
n := s.recv(buf[:]) catch e {};
s.close();

// server
ln := net::serve(addr) catch e { return; };
conn := ln.accept() catch e { return; };   // blocks for a client
```

- **`TcpStream`** (methods): `send(data) -> usize`, `recv(buf) -> usize` (0 = closed),
  `close()`.
- **`TcpListener`** (methods): `accept() -> TcpStream`, `close()`.
- **Free fns:** `init()`, `shutdown()`, `dial(addr)`, `serve(addr)` — all `! NetError`.

> A complete loopback TCP echo (server thread + client round-trip, combining net +
> thread + addr) is in `tests/fixtures/stdlib/net_echo_app.k2`. UDP, DNS
> (`getaddrinfo`), and a small HTTP client are the natural next additions.

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

## General-purpose modules

### `std.path`

Filesystem path strings — pure manipulation, no I/O. Both `/` and `\` are accepted
as separators; `join` writes the platform `SEP`. Query functions return sub-slices
(no allocation); builders take an `*Arena`.

```k2
path::basename("a/b/c.txt")            // "c.txt"
path::dirname ("a/b/c.txt")            // "a/b"   ("." when no separator)
path::extension("c.txt")               // ".txt"  (with the dot; "" if none)
path::stem("c.txt")                    // "c"
path::is_absolute("/x")                // true (also "C:\…" and "\unc")
path::has_extension("c.k2", "k2")      // true (leading dot optional)
path::join(&a, "a/b", "c.txt")         // "a/b\c.txt"
path::with_extension(&a, "c.txt", "md")// "c.md"
```

Invariant: `basename(p)` == `stem(p)` ++ `extension(p)`.

### `std.time`

Wall-clock time, a monotonic clock, sleeping, and a UTC calendar breakdown
(Windows backend, kernel32).

```k2
secs := time::unix_seconds();          // i64 seconds since 1970-01-01 UTC
ms   := time::unix_millis();
dt   := time::utc(secs);               // DateTime { year, month, day, hour, minute, second, weekday }

start := time::now();                  // monotonic Instant
time::sleep_ms(16u32);
ns := time::since_nanos(start);        // also since_millis / since_seconds
boot := time::monotonic_millis();      // GetTickCount64, coarse monotonic
```

`utc` is exact for any time ≥ the epoch (Howard Hinnant's civil-from-days). `weekday`
is `0`=Sunday … `6`=Saturday.

### `std.crypto`

Hashing and checksums — pure computation.

```k2
d := crypto::sha256("abc");                     // FIPS 180-4 SHA-256 → Digest
h := crypto::to_hex(&a, d);                      // "ba7816bf8f01cfea…"

buf: [32]u8 = .{};                               // or write into your own buffer
crypto::sha256_into("abc", buf[0..32usize]);

c := crypto::crc32("123456789");                // 0xcbf43926 (IEEE)
k := crypto::fnv1a_64("key");                   // fast non-crypto hash (and fnv1a_32)
```

`sha256`/`sha256_into` match the standard test vectors. It's a software SHA-256 — fine
for integrity/checksums and content addressing, not audited for adversarial use.

### `std.serde`

Reflection-driven JSON, both directions, with **no per-type code**. One generic serializer
and one generic parser walk the type's `core::type_info` for its *shape* and an `core::any`
for the field *values/slots*, recursing through nested structs and slices automatically.

```k2
#import std.heap as heap;
#import std.serde as serde;

Player :: struct { name: []const u8, pos: Point, hp: u8, alive: bool, scores: []i32 }

a := heap::make();
pl: Player = .{ "Mario", .{ 10, 20 }, 100u8, true, xs };
js := serde::to_json(Player, pl, &a);
//   {"name":"Mario","pos":{"x":10,"y":20},"hp":100,"alive":true,"scores":[1,2,3]}

// …and back. `from_json` returns `?T` (null on a structural parse error):
if serde::from_json(Player, js, &a) |back| { /* back == pl, field for field */ }
```

Both `to_json($T, v, arena)` and `from_json($T, text, arena) -> ?T` handle:

- ints of every width, floats (minimal form — `2.5`, not `2.500000`), `bool`
- `[]const u8`/`[]u8` as JSON strings (with `\"`, `\\`, `\n`, `\t` escaping/unescaping)
- structs, **recursively** (nested structs, string fields)
- slices — scalars (`[]i32`), structs (`[]Point`), **and nested** (`[][]i32`) — as JSON arrays
- **optionals** (`?T`): `null` for none, else the payload (scalar / string / struct)
- **enums**: the variant name as a JSON string (`"Blue"`)
- on parse, **unknown object keys are skipped**, and missing fields stay zero-initialized

Deserialization constructs the value reflectively: it zero-inits a `result: T`, wraps a
*mutable* `Any` over its address, and writes each parsed field through the real field
address that `any_field_at` hands back. Arrays/strings are allocated in the arena.

How it works (the "one serializer, two speeds" design from docs/12): the *structure* comes
from `type_info` (a struct's `id` sizes/tags slice + optional-payload elements; alignment is
derived recursively from field types) and the *bytes* come from `Any`, so adding a new type
needs zero serializer/parser changes.

Limit: enum *payloads* aren't emitted (only the variant name — `TiVariant` carries no payload
type), and `?*T` / maps aren't modeled.

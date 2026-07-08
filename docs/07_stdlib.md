# Standard Library

Fels's standard library is called `std`. It stays minimal, and it is allocation-free where it
can be.

Here are the primary modules:

## `std.io`
The I/O interfaces and utilities. Everything here is synchronous and allocation-free.

**Interfaces:**
- `Writer`: `write`, `flush`
- `Reader`: `read`

**Implementations & Tools:**
- `stdout()`, `stderr()`: Return `Stdout` / `Stderr` structs that implement `Writer`.
- `fixed_buf()`: A 256-byte buffer on the stack that implements `Writer` (`FixedBuf`).
- `null_writer()`: A writer that discards its output but counts the bytes (`NullWriter`).

**Extension Methods (on `*Writer`):**
- `write_all`, `write_line`, `write_char`, `write_repeat`
- `write_bool`, `write_u64`, `write_i64`, `write_hex_u64`

**Printing:** `print`, `println`, `eprint` and `eprintln`, and `w.write_fmt(f)` and
`w.write_fmt_line(f)` on any `*Writer`, take a `Format`: a string literal with values in braces.

```fels
io::println("{name} has {n} items");
io::println("{p}");                                  // Point{ x: 1, y: 2 }
io::println("[{x:>8}] [{id:06}] {flags:x} {ratio:.2} {s:?}");
```

- Any expression goes in the braces, and `{{` and `}}` are braces of the text. The compiler
  reads the literal: the values are checked where the call is, and a mistake points at its
  place in the string. No string literal fits in the braces; put one in a local first.
- A spec after a `:` is `[[fill]align][0][width][.precision][kind]`. Align is `<`, `>` or `^`
  (numbers go right by themselves, the rest left); `0` pads a number with zeros after its sign;
  the precision is the digits after a float's point; the kind is `x` or `X` for hex, `b` binary,
  `o` octal, and `?` for text in quotes. The width counts bytes.
- Every type prints: numbers, `bool`, text, an enum as its variant, an error as its name, an
  optional as its value or `null`, slices and arrays as `[1, 2]`, structs as
  `Point{ x: 1, y: 2 }` (text inside them in quotes), pointers as their address. A float shows
  up to 15 significant digits, without the zeros at the end (`3.14159265`, `0.1`, `2`).
- A type with a method `format :: fn(self, f: *Formatter)` prints itself, also inside other
  values. `f.text("…")` writes text and `f.value(x, "spec")` a value:

  ```fels
  Money :: struct {
      cents: i64,
      pub format :: fn(self: Money, f: *Formatter) {
          f.value(self.cents / 100, "");
          f.text(",");
          f.value(self.cents % 100, "02");
      }
  }
  ```

- A function of the program can take a `Format` too, and pass it on (`println(f)`) or write it
  (`w.write_fmt(f)`). Its values are read when it is written, so a log call that drops its
  message reads none.
- Any other `[]const u8` passed as a `Format` prints as it is, braces and all, so text from data
  is never read as a format.
- A format in a generic function cannot print values yet: its code is a lambda, and a lambda
  there cannot use the function's values (KNOWN_ISSUES).

`print_u64`, `print_i64`, `print_hex_u64`, `print_bool`, `eprint_u64` and `eprint_i64` are
deprecated: a format says the same (`print("{n}")`).

## `std.fmt`
Formatting utilities built on top of `std.io.Writer`.

- `write_padded_left`, `write_padded_right`, `write_padded_center`
- `write_u64_padded`, `write_hex_u64_padded`
- `join_bytes(w: *Writer, items: []const []const u8, sep: []const u8)`

## `std.mem`
Safe, generic helpers for typed memory.

- `eql($T: type, a: []const T, b: []const T) -> bool`
- `starts_with`, `ends_with`, `contains`, `index_of`
- `copy($T: type, dest: []T, src: []const T)`
- `fill($T: type, slice: []T, value: T)`
- `swap`, `reverse`

For bytes there are specialized aliases: `eql_bytes`, `copy_bytes` and `zero`.
`compare_bytes(a, b) -> i32` orders two texts byte by byte (-1, 0 or 1, a prefix first), and
`less_bytes(a, b) -> bool` is that order as a comparison, for sorting text.

## `std.bytes`
This module reads and writes fixed-width integers at an explicit offset in a byte slice. It
is meant for wire formats and file headers, where the integers sit at known offsets in a
stated byte order.

```fels
#import std.bytes as bytes;

parse :: fn(packet: []const u8) -> u32 ! bytes::BytesError {
    id := bytes::read_u32_le(packet, 4)?;      // bytes 4..8, least significant first
    return id;
}

build :: fn(out: []u8, length: u16) -> void ! bytes::BytesError {
    bytes::write_u16_be(out, 0, length)?;      // bytes 0..2, most significant first
}
```

- **Names:** `read_<width>_<order>` and `write_<width>_<order>`, where the width is `u16`,
  `u32` or `u64` and the order is `le` (little-endian) or `be` (big-endian). There are also
  `read_u8` and `write_u8`, which have no order. Reads have the shape
  `(self: []const u8, off: usize) -> T ! BytesError`, and writes have the shape
  `(self: []u8, off: usize, v: T) -> void ! BytesError`. For a signed value, cast the
  unsigned one: `read_u16_le(b, 0)? as i16`.
- **Bounds are always checked**, in every build mode. (Plain slice indexing is checked too,
  unless the build is `release_fast`.) An integer that would not lie wholly inside the slice
  fails with `.out_of_bounds`, and in that case nothing was read or written. The offset can
  be any `usize`, even `usize` max, and the check cannot overflow. `BytesError` is its own
  error set. If your parser returns a different one, handle it with `catch`, because `?`
  needs matching sets.
- **No alignment is assumed.** The integers are assembled from single bytes, so an odd
  offset or a slice that starts mid-buffer is fine, and byte order does not depend on the
  machine.
- **Unchecked access** goes through `core::unaligned_read(T, ptr)` (little-endian on the
  supported targets). It is meant for a bound you have already proven.
- When you import a function by name (`#import std.bytes.{ read_u32_le };`), you can also
  call it as a method: `packet.read_u32_le(4)?`.

See `tests/fixtures/stdlib/bytes_app.fels` for the module at work.

## `std.utf16`
UTF-8 ⇄ UTF-16 conversion, written in plain Fels with no OS calls, so it behaves the same on
every target. (Windows' `MultiByteToWideChar` / `WideCharToMultiByte` do a related job.
Nothing here depends on them, but the test suite checks that the two agree on every Unicode
scalar value.)

```fels
#import std.utf16 as utf16;
#import std.heap as heap;

// UTF-8 text -> a NUL-terminated wide string for a Win32 "W" function.
to_wide :: fn(a: *heap::Arena, text: []const u8) -> []u16 ! utf16::Utf16Error {
    return utf16::alloc_utf16z(a, text);
}

// Size first, then convert into a buffer you own.
into_buffer :: fn(text: []const u8, buf: []u16) -> usize ! utf16::Utf16Error {
    need := utf16::utf16_len(text)?;               // exact result length; fails on malformed input
    if need > buf.len { fail .buffer_too_small; }
    return utf16::utf8_to_utf16(text, buf);
}
```

- **Representations.** UTF-8 is a `[]const u8`. Nothing guarantees that a string is valid
  UTF-8, which is why every conversion validates. UTF-16 is a `[]const u16` of code units in
  the machine's own order, with no byte-order mark and no serialisation. A character above
  U+FFFF is a surrogate pair.
- **Functions.** For sizing, `utf16_len(src8)` and `utf8_len(src16)` give the exact size of
  the result. To convert into your own buffer, `utf8_to_utf16(src, dst)` and
  `utf16_to_utf8(src, dst)` return the number of units or bytes written. To allocate from an
  arena, use `alloc_utf16(a, src)`, `alloc_utf16z(a, src)` or `alloc_utf8(a, src)`. With
  `alloc_utf16z`, one extra unit past the end is `0`, so `.ptr` is a Win32 `LPCWSTR`, and
  the returned length does not count that unit.
- **Errors (`Utf16Error`).** The errors are `.invalid_utf8`, `.invalid_utf16`,
  `.buffer_too_small` and, for the arena functions, `.out_of_memory`. You inspect one with
  `e == .invalid_utf8` in a `catch`.
- **Malformed input is an error and is never repaired**, and there is no replacement
  character. UTF-8 is rejected for a stray continuation byte, `C0`/`C1`/`F5`–`FF`, a
  truncated sequence, a non-continuation where one is required, an overlong encoding, an
  encoded surrogate (`ED A0`–`BF`), and anything above U+10FFFF. UTF-16 is rejected for a
  high surrogate that is not followed by a low one, and for a low surrogate with no high one
  before it. U+0000 is an ordinary character.
- **Capacity is explicit.** A conversion first validates and counts, then checks the
  destination, and only then writes. If the input is malformed or `dst` is too small, it
  fails and **`dst` is not modified**. When `dst` is longer than needed, its extra units stay
  as they were. The arena functions allocate exactly the result (plus the terminator for
  `alloc_utf16z`). The arena owns that memory, and nothing is freed.

See `tests/fixtures/stdlib/utf16_app.fels` for hand-picked and exhaustive cases, and
`utf16_win_app.fels` for the agreement with the Windows APIs.

## `std.fs`
Minimal synchronous file I/O, on Windows and Linux.

- `open(path)`: Open an existing file for reading
- `create(path)`: Create or truncate a file for writing
- `append(path)`: Open a file for appending
- `read_all(path, &a)`: Read a whole file into the arena
- `delete(path)`: Remove a file
- `exists(path)`: Check whether a file or folder exists. `is_dir(path)` checks for a folder.
- `make_dir(path)`: Make a folder (one that is already there is fine). `make_dirs(path)` makes
  the folders above it too, and `remove_dir(path)` removes an empty folder.
- `open_dir(path)`: Walk a folder with the `DirIter` it returns. `dir_next()` gives the next
  entry's name (`.` and `..` included), or null at the end, and the name is valid until the
  next call. `dir_is_dir()`, `dir_size()` and `dir_is_reparse()` describe that entry, and
  `dir_close()` ends the walk. On Linux, `dir_size()` is always 0.
- You get back a `File` struct, which implements both `Reader` and `Writer`.
- Paths are UTF-8, like all Fels text, and can be up to 1023 bytes long. On Windows the
  runtime turns them into the UTF-16 that the `*W` functions take. `dir_next` gives you names
  in UTF-8 too.

## `std.process`
Process management, on Windows and Linux.

- `spawn(cmd)`: Spawn a child process (returns `Child`)
- `wait(child)`, `try_wait(child)`, `kill(child)`, `release(child)`
- `current_pid()`
- `get_env`, `set_env`, `unset_env`
- `command_line`: the command line as one text
- `args(&a)`: the arguments, with the program first. On Windows they are split from the
  command line the way the C runtime splits it, and `split_command_line(line, &a)` does the
  same for any line (quotes keep spaces, and `\"` is a quote). On Linux they are exactly as
  the kernel passed them.

## `std.ptr`
Pointer manipulation and conversions, which require `unsafe` in some contexts.

- `to_addr(p: *T) -> usize`
- `from_addr($T: type, addr: usize) -> *T`
- `add_bytes`, `sub_bytes`, `diff_bytes`
- `is_aligned`, `align_down`, `align_up`
- `is_null`

## `std.bits`
Bit-twiddling utilities.

- `count_ones_u32`, `count_ones_u64`
- `leading_zeros_u32`, `trailing_zeros_u64`, etc.
- `rotate_left_u32`, `rotate_right_u64`, etc.
- `is_power_of_two_u32`
- `bit_u32`, `set_bit_u32`, `clear_bit_u32`, `toggle_bit_u32`

## `std.atomics`
Atomic operations over shared memory, the foundation for lock-free code and for
synchronising threads. Each operation acts on a pointer to the value and **infers the
element type**, so you never write an explicit `$T`. Read-modify-write helpers return the
**previous** value, as in C and LLVM. The helpers default to **sequentially consistent**
ordering. For finer control, call the `core::atomic_*` builtins with an ordering constant
(`Relaxed`/`Acquire`/`Release`/`AcqRel`/`SeqCst`).

```fels
#import std.atomics;

counter: u32 = 0u32;
old := atomics::fetch_add(&counter, 1u32);          // returns the previous value
if atomics::compare_exchange(&counter, 1u32, 100u32) { /* swapped */ }
```

**Compile-time type contracts.** Each operation is guarded by a `constraint`
(`Native`/`Numeric`/`Integer`) built on `core::type_info` reflection. That way, misuse is a
clear compile error and not a backend failure. Here is what a bitwise op on a float gives you:
```
error: type `f64` does not satisfy `Integer`: expected an integer type
```

- **Load/store:** `load`, `store`, `load_acquire`, `store_release`
- **Read-modify-write** (these return the previous value): `swap`, `fetch_add`/`fetch_sub` (numeric,
  float-aware), `fetch_mul`/`fetch_div` (numeric, CAS loop), `fetch_max`/`fetch_min`
  (integer), `fetch_and`/`fetch_or`/`fetch_xor`/`fetch_nand` (integer),
  `fetch_shl`/`fetch_shr` (integer, CAS loop)
- **Compare-exchange:** `compare_exchange(p, expected, desired) -> bool`,
  `compare_exchange_value` (returns the value actually seen)
- **Fences:** `fence()`, `fence_acquire()`, `fence_release()`
- **Flags / spinlock:** `is_set`, `test_and_set`, `clear`, `wait_until_set`,
  `wait_until_eq`, `spin_lock`, `spin_unlock`

### `Atomic(T)` — a typed atomic cell

The free functions act on a raw `*T`. `Atomic(T)` *wraps* the value instead, so the type
itself documents that the value is shared, and the operations read as methods. The element
type is recovered from the receiver, so you never write `$T`:

```fels
#import std.atomics;
#import std.atomics.{Atomic};         // bring the type name into scope

counter: Atomic(u32) = .{ 0u32 };     // or: counter := Atomic::make(0u32);
old := counter.add(1u32);             // returns the previous value
if counter.cas(1u32, 100u32) { ... }  // compare-and-swap
n := counter.get();
```

The methods are `get`/`set`, `get_acquire`/`set_release`, `exchange`, `cas`/`cas_value`,
`add`/`sub`/`mul`/`div` (numeric), and `max`/`min` and `and`/`or`/`xor`/`nand` (integer).
The cell itself only checks that `T` is `Native`. The methods do not carry the narrower
contracts of their free-function counterparts, so `and` on an `Atomic(f64)` passes
`fels check` and then fails in code generation. Use the free functions when you want the
clear compile error.

> Atomic increments across threads lose nothing under contention. That is the whole point,
> because a plain `+= 1` would race. See `tests/fixtures/stdlib/atomics_thread_app.fels`,
> and `atomic_cell_app.fels` for the `Atomic(T)` method API.

## `std.thread`
Native OS threads and structured helpers. Fels favours *real threads* over async/await.
There is no function colouring, no hidden executor and no heap-allocated coroutine frame:
a thread is a stack plus an entry point. An entry has the shape `fn(*void) -> u32`. It
receives a single context pointer and returns an exit code.

An ordinary function value in Fels is a fat `{fn, env}` closure, which a C ABI can't call.
So you hand the entry over as **`core::fn_ptr(worker)`**, the raw thin function pointer.
The context pointer you pass must outlive the thread. Join the thread before its data
leaves scope, or put the data on a long-lived arena.

```fels
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

- **`Thread`** (methods): `join() -> u32` (waits, returns the exit code, closes the handle),
  `detach()` (fire-and-forget), `is_running()` (non-blocking poll), `ok()`. On Linux an exit
  code keeps only its low 8 bits, so return 0 to 255 if you read it with `join()`.
- **`spawn(entry, arg) -> Thread`**: start a thread. `entry` is `core::fn_ptr(fn)`.
- **Helpers:** `current_id()`, `sleep(ms)`, `yield_now()`, `cpu_count()`.
- **`ThreadGroup`**: structured fan-out. `spawn(entry, arg)` adds a thread, and `join_all()`
  blocks until the whole batch finishes (the batch can't outlive the call site).
  `thread::group()` makes an empty one.

```fels
g := thread::group();
i: usize = 0usize;
while i < thread::cpu_count() as usize { g.spawn(core::fn_ptr(worker), cp); i += 1usize; }
g.join_all();                    // wait for all
```

> Locks, waiting and a blocking queue are in [`std.sync`](#stdsync), while counters and
> flags need only `std.atomics`. See `tests/fixtures/stdlib/thread_app.fels`.

## `std.sync`
Mutual exclusion and waiting between threads, built on the operating system's own
primitives. A thread that cannot proceed sleeps in the kernel instead of polling in a loop.
On Windows, a `Mutex` is a slim reader/writer lock (`SRWLOCK`) used exclusively, and a
`CondVar` is a `CONDITION_VARIABLE`. On Linux, they are built on `futex(2)`. Both are one
machine word kept in your own struct, so there is no allocation, no initialisation call and
nothing to destroy. **All zero bits is the unlocked state**, which makes `m: Mutex = .{};`
correct as a local, as a struct field and as a global in static storage.

```fels
#import std.sync.{ Mutex, CondVar };

lock: Mutex = .{};
ready: bool = false;                  // guarded by `lock`
cv: CondVar = .{};

// a waiter
lock.lock();
while !ready { cv.wait(&lock); }      // always in a loop: wait() can return with no signal
lock.unlock();

// a signaller
lock.lock();
ready = true;
lock.unlock();
cv.signal();
```

- **`Mutex`**: `lock()` sleeps until it holds the lock, `try_lock() -> bool` takes it only if
  it is free right now, and `unlock()` releases it. Pair `lock()` with `defer m.unlock();` so
  the lock is released on every exit from a function.
- **`CondVar`**: `wait(&m)` releases `m`, sleeps, and holds `m` again when it returns.
  `wait_timeout(&m, ms) -> bool` gives up after `ms` milliseconds (0xFFFFFFFF means never) and
  returns `false` when the time ran out. `signal()` wakes one waiter and `broadcast()` wakes
  all of them. You may call either one with or without the lock held.
- **A wait can return early.** A thread may be woken by nothing (a *spurious wake-up*, which
  both operating systems allow), and a `signal()` sent while nobody waits is forgotten. That is
  why the condition lives in data guarded by the mutex, and why every wait sits in a
  `while !condition { … }` loop, as above. When `wait_timeout` returns `true`, that means
  "woken", not "the condition holds".
- **Rules.** Share a lock by address, and do not copy one that is in use. A `Mutex` is not
  recursive, so locking it again from the thread that holds it deadlocks. Unlocking one that
  the thread does not hold is undefined. Nothing is fair, and there is no ownership or
  poisoning check. Do not move or free a lock while a thread holds it or sleeps on it. Join
  the threads first.

**`Queue(T)`** is a bounded blocking FIFO for any number of producers and consumers. It is
**bounded** by design. It owns no memory: you hand it the storage, and that fixes the
capacity. So nothing is allocated behind your back, a producer that outruns its consumers
waits instead of exhausting memory, and there is no allocator to share between threads.

```fels
#import std.sync;

buf: [64]i32 = .{};
q := sync::make_queue(i32, buf[:]);     // capacity 64; `buf` must outlive every user

q.push(7);                              // sleeps while the queue is full; false once closed
v := q.pop() ?? -1;                     // sleeps while it is empty; null once closed and drained
```

- `push(item) -> bool`, `try_push(item) -> bool` (false if full, closed or capacity 0),
  `pop() -> ?T`, `try_pop() -> ?T` (null if empty), `len()`, `capacity()`, `is_closed()`.
- **Shutdown.** `close()` ends the queue and wakes everyone blocked on it. After that, `push`
  and `try_push` return `false`. Items already queued can still be popped, and when they run
  out, `pop` returns `null`. So a pipeline stops like this: the producers finish, the owner
  calls `close()`, the consumers drain the queue and see `null`, the owner joins them, and
  only then does the owner release the storage. Calling `close()` again does no harm.
- **Destruction.** A `Queue` holds no resource, so there is no `deinit`. What must not happen
  is freeing or moving the storage, or the `Queue` itself, while a thread is still inside a
  call. Hence the rule "join, then release".
- Items leave the queue in the order they went in. With several consumers, the order in which
  they finish is up to the scheduler. A `Queue` over empty storage can hold nothing, so `push`
  fails and `pop` waits for `close()`.

There is no reader/writer lock, semaphore, barrier, one-shot or unbounded channel yet. See
`tests/fixtures/stdlib/sync_app.fels` for contention with exact totals, a two-thread hand-off
that must alternate strictly, a broadcast, timed waits, and many producers against many
consumers with every item delivered exactly once.

## `std.com` — COM and Windows Runtime types
The data types of COM and the Windows Runtime. The module makes no operating-system call, so it
compiles for every target. It has `Guid`, `HRESULT`, `IUnknown` and `IInspectable` with their
vtables, and a reference counter for objects you implement.
[`std.winrt`](#stdwinrt--calling-com-and-the-windows-runtime-windows-only) is the part that
calls Windows.

Every layout, GUID and constant was compared with the official Windows SDK headers
(`guiddef.h`, `winerror.h`, `unknwn.h`, `inspectable.h`, `activation.h`). For that, the headers
were compiled with clang for `x86_64-pc-windows-msvc`, printing `sizeof`, `offsetof`, each
interface's `__uuidof` and each constant. `#assert`s in the module pin the layouts, so a wrong
offset is a build error.

- **`Guid`**: 16 bytes, aligned to 4, made of `data1: u32`, `data2: u16`, `data3: u16` and
  `data4: [8]u8` (an IID and a CLSID are GUIDs). It has `eq(&other)`, `is_null()` and
  `format(buf) -> usize`, which writes `{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}` in upper case.
  `buf` needs `GUID_TEXT_LEN` = 38 bytes, else the result is `.buffer_too_small`.
  `parse_guid(text)` takes exactly 8-4-4-4-12 hex digits in either case, with the braces or
  without, and anything else is `.invalid_format`. The well-known ids are typed constants
  (`IID_IUnknown`, `IID_IInspectable`, `IID_IAgileObject`, `IID_IActivationFactory`), and you
  pass them by address (`&com::IID_IUnknown`). They live in read-only data, so never write to
  one.
- **HRESULT** is an `i32` (`Hresult`). A negative value is a failure, and zero or more is a
  success (`S_FALSE` = 1 is a success that means "no"). The `winerror.h` codes you meet are
  constants (`S_OK`, `E_FAIL`, `E_NOINTERFACE`, `E_INVALIDARG`, `RPC_E_CHANGED_MODE`,
  `REGDB_E_CLASSNOTREG`, …). `succeeded(hr)`, `failed(hr)`, `facility(hr)`, `code(hr)` and
  `from_win32(err)` (`HRESULT_FROM_WIN32`) take one apart or build one.
- **From an HRESULT to an error.** `check(hr)` succeeds on any success code and fails with
  `ComError` otherwise. The common codes have their own names (`.no_interface`, `.invalid_arg`,
  `.out_of_memory`, `.class_not_registered`, `.changed_mode`, …), and any other failure is
  `.other`, which no longer says which code it was. If you need the code, keep the HRESULT.
- **From an error back to an HRESULT.** The module has no function for this direction. You
  write it where the error is caught, or in a function of your own that takes the `ComError`,
  because an error is a value you can pass on:

  ```fels
  read_header(self) catch e {
      if e == .no_interface { return E_NOINTERFACE; }
      return E_FAIL;
  };
  return S_OK;
  ```
- **`IUnknown`** `{ vtbl }` comes with its vtable `{ query_interface, add_ref, release }`, and
  the three methods are on the struct as well. **`IInspectable`** (the base of every Windows
  Runtime interface) adds `get_iids`, `get_runtime_class_name` and `get_trust_level`.
  **`IActivationFactory`** adds `activate_instance`. You call a COM method through the table,
  with the interface pointer first: `p.vtbl.release(p)`. On x86-64 Windows there is one calling
  convention, so any Fels function with matching parameter and result types fits a table slot.
- **`RefCount`**: one atomic 32-bit counter for an object you implement. `new_refcount()`
  starts at 1 (the creator's reference), and `add()` and `release()` return the new count. A
  `release()` that returns 0 means the object is unreferenced and yours to free.

**Ownership is by reference count and nothing else owns anything.** An interface pointer that a
function hands you (an out-parameter, or what `query_interface` returns) carries one reference,
and that reference is yours to release exactly once. A pointer you are only lent is not yours to
release, and you `add_ref` it if you want to keep it. Releasing the last reference destroys the
object, and any later use is a crash. The counts that `add_ref` and `release` return are for
diagnostics. Never branch on them.

**Declaring an interface** means listing its vtable in header order, with `this` first, and then
asserting the offsets against the header. **Implementing one** takes a struct whose first field
is the vtable pointer, plus a vtable that is static data. That vtable is a global initialised
with the functions, and no table is built at run time:

```fels
#import std.com;
#import std.com.{ Guid, IUnknown, IUnknownVtbl, RefCount };

Counter :: struct { vtbl: *IUnknownVtbl, rc: RefCount }

c_query :: fn(self: *IUnknown, iid: *const Guid, out: **void) -> i32 {
    c := unsafe (self as *Counter);
    if iid.eq(&com::IID_IUnknown) {
        *out = unsafe (self as *void);
        n := c.rc.add();                      // the pointer handed out is a new reference
        return com::S_OK;
    }
    *out = unsafe (core::ptr_from_int(*void, 0usize));
    return com::E_NOINTERFACE;
}
c_add_ref :: fn(self: *IUnknown) -> u32 { c := unsafe (self as *Counter); return c.rc.add(); }
c_release :: fn(self: *IUnknown) -> u32 { c := unsafe (self as *Counter); return c.rc.release(); }

COUNTER_VTBL: IUnknownVtbl = .{ c_query, c_add_ref, c_release };

#entry
main :: fn() -> i32 {
    obj: Counter = .{ &COUNTER_VTBL, com::new_refcount() };
    p := unsafe ((&obj) as *IUnknown);
    n := p.add_ref();                         // 2: the caller holds a reference of its own
    n = p.release();                          // 1
    return 42;
}
```

## `std.winrt` — calling COM and the Windows Runtime (Windows only)
This is the part of the COM and Windows Runtime story that calls Windows. It starts COM and the
Runtime on a thread, creates objects, activates runtime classes, and handles `HSTRING`. It is
thin on purpose. Each function that mirrors an OS call keeps the call's shape and returns its
HRESULT unchanged, for you to pass to `com::check`. The few that only return a status
(`co_initialize`, `ro_initialize`) or have one natural result (`activation_factory`, `new_guid`)
are fallible. Nothing runs on its own: there is no hidden initialisation and no thread-local
state. A program that imports the module for another target fails to link, as it would for any
missing Win32 function. The COM entry points come from `ole32.dll` and the Runtime ones from
`combase.dll`. The Windows SDK has no `combase.lib` (it ships those entry points in
`runtimeobject.lib`), so the linker driver hands LLD that library, and `felsld` imports the DLL
directly.

- **Apartments.** `co_initialize(mode)` / `ro_initialize(kind)` apply to the calling thread.
  Each success is paired with one `co_uninitialize()` / `ro_uninitialize()` on the same thread,
  and that includes a success that returned `S_FALSE` ("already initialised"). Initialising a
  thread the other way fails with `.changed_mode`. Use the multithreaded kinds
  (`CO_MULTITHREADED`, `RO_MULTITHREADED`) unless the thread pumps a message loop.
- **Creating objects.** `co_create_instance(&clsid, CLSCTX_INPROC_SERVER, &iid, &out)` is
  `CoCreateInstance`. It gives the HRESULT back, and `*out` is an owned interface pointer.
  `activation_factory(class_id, &iid)` is `RoGetActivationFactory`. It takes the class name as
  an HSTRING handle (`.h`) and gives back an owned `*IUnknown` for you to cast to the factory
  interface, or `.class_not_registered` if there is no such class.
  `activate_instance(class_id)` is `RoActivateInstance`, and `new_guid()` is `CoCreateGuid`.
  `co_task_mem_free(p)` frees what the OS allocated for you with the COM task allocator, such
  as the array that `IInspectable.get_iids` returns.
- **`HString`**: an owned `HSTRING`. `.h` is the one-pointer handle to pass to the OS, and the
  null handle is the empty string. `hstring(units)` copies UTF-16 in (`WindowsCreateString`),
  and `hstring_from_utf8(text, scratch)` converts through your `[]u16` scratch buffer first.
  `release()` deletes it (idempotent). There are also `duplicate()`, `len()`, `is_empty()`,
  `units()` (a borrowed view, valid until `release()`), `eq(&other)` (case-sensitive) and
  `to_utf8(out)`. An HSTRING may hold zeros and unpaired surrogates, and `to_utf8` refuses the
  latter with `.invalid_utf16`.
- **`HStringRef`**: a borrowed `HSTRING` over a buffer you already hold, with no allocation and
  nothing to release. It is the cheap way to pass a class name. `init(z)` takes the UTF-16
  *with its terminating zero*. The struct must not move after `init`, and the buffer must
  outlive every use of `.h`.

```fels
#import std.com;
#import std.com.{ Guid, IInspectable };
#import std.winrt;
#import std.winrt.{ HString, HStringRef };
#import std.utf16;

#entry
main :: fn() -> i32 {
    winrt::ro_initialize(winrt::RO_MULTITHREADED) catch e { return 1; };

    name_buf: [64]u16 = .{};
    n := utf16::utf8_to_utf16("Windows.Foundation.Uri", name_buf[0..63]) catch e { return 2; };
    name_buf[n] = 0u16;
    class_name: HStringRef = .{ .{}, 0usize };
    class_name.init(name_buf[0..n + 1usize]) catch e { return 3; };

    // `IUriRuntimeClassFactory`, from windows.foundation.h
    IID_UriFactory: Guid = .{ 0x44A9796Fu32, 0x723Eu16, 0x4FDFu16, .{ 0xA2u8, 0x18u8, 0x03u8, 0x3Eu8, 0x75u8, 0xB0u8, 0xC0u8, 0x84u8 } };
    factory := winrt::activation_factory(class_name.h, &IID_UriFactory) catch e { return 4; };
    ig := factory.release();                  // every pointer we are handed is ours to release
    winrt::ro_uninitialize();
    return 42;
}
```

`tests/fixtures/stdlib/winrt_app.fels` goes further and runs against the real system. It
compares GUID text and parsing with `StringFromGUID2` / `IIDFromString`, and it takes an HSTRING
through every operation. It calls the OS's in-memory `IStream` through a vtable declared from
`objidl.h`. It has a COM object written in Fels that the OS calls back (`IStream::CopyTo` writes
into it). And it activates `Windows.Foundation.Uri` and reads it through its interfaces, with the
reference counts checked.

Here is what the module does not do. There are no events, delegates or async. There is no
generated projection of a runtime class, so you declare the interfaces you call. There is no
smart pointer: a release is a call you write, with `defer`. And there is no marshalling across
apartments.

## `std.net` — networking
TCP and UDP, over Winsock2 on Windows and over the socket system calls on Linux. The code is
layered across a subdirectory module, so each piece stays small and focused. Here are the layers
from the bottom up:

| Module | What it gives you |
| --- | --- |
| `std.net.os` | The raw socket calls (`sys_` functions over the runtime's socket layer: Winsock2 on Windows, socket system calls on Linux), protocol constants, the `sockaddr_in` wire struct, the shared `NetError`, and `addr ⇄ wire` conversions. The foundation. Reach for it directly only for an option the upper layers don't expose. |
| `std.net.addr` | `IpV4` / `SocketAddr`: parse, format, classify (`is_loopback`/`is_unspecified`), `to_net`/`from_net`, `#derive(Eq)`. |
| `std.net.socket` | `Socket`: the typed handle and the options shared by every protocol (`set_recv_timeout`/`set_send_timeout`, `set_reuse_addr`, `set_broadcast`, `set_nonblocking`, `shutdown`, `bind_to`, `local_addr`). |
| `std.net.tcp` | `TcpStream` / `TcpListener`: streams plus `send_all` / `recv_exact`, `set_nodelay`, and `accept` returning the peer address. |
| `std.net.udp` | `UdpSocket`: datagrams (`send_to` / `recv_from`) and the connected `connect`+`send`/`recv` shortcut. |
| `std.net` | A thin facade re-exporting the lifecycle (`init` / `shutdown` / `last_error`) and the constructors (`connect` / `listen` / `udp_bind`). |

It leans on the newer language features throughout: in-struct methods, `#derive`, and
`!`-fallible returns. Every layer that works with sockets fails with the one shared
`os::NetError`. Parsing an address fails with `addr::AddrError`.

**Addresses** (`std.net.addr`): `IpV4` has `#derive(Eq)` and a hand-written `format` that
renders a dotted quad, and `SocketAddr` has a derived `Eq` that recurses into `IpV4.eq`:
```fels
#import std.net.addr as addr;
ip  := addr::parse("127.0.0.1") catch e { ... };   // fallible
sa  := addr::socket_addr(addr::localhost(), 8080u16);
sa.format(&sb);                                      // "127.0.0.1:8080"
```

**TCP**: call `init()` once, then `connect(addr)` / `listen(addr)`:
```fels
#import std.net as net;
#import std.net.addr as addr;

net::init() catch e { return; };

// client
s := net::connect(addr::socket_addr(addr::localhost(), 8080u16)) catch e { return; };
s.send_all("ping") catch e {};       // loops over short writes
n := s.recv(buf[:]) catch e { return; };   // 0 = peer closed
s.close();

// server
ln := net::listen(sa) catch e { return; };
a  := ln.accept() catch e { return; };   // a.stream + a.peer (blocks for a client)
```

**UDP**: connectionless datagrams, or `connect` to pin a default peer:
```fels
#import std.net.udp as udp;

srv := udp::bind(addr::socket_addr(addr::any(), 9000u16)) catch e { return; };
d   := srv.recv_from(buf[:]) catch e { return; };   // d.len + d.from
ignored := srv.send_to("pong", d.from) catch e { return; };  // reply to sender
```

- **`TcpStream`**: `send`/`send_all`, `recv`/`recv_exact`, `set_nodelay`,
  `set_read_timeout`/`set_write_timeout`, `local_addr`, `shutdown_write`, `close`.
- **`TcpListener`**: `accept() -> Accepted{stream, peer}`, `accept_stream()`, `local_addr`, `close`.
- **`UdpSocket`**: `send_to`/`recv_from`, `connect`+`send`/`recv`, `set_broadcast`,
  `set_read_timeout`, `local_addr`, `close`.
- The facade re-exports the types of its submodules: `net::TcpStream`, `net::TcpListener`,
  `net::Accepted`, `net::UdpSocket`, `net::Datagram`, `net::SocketAddr` and `net::NetError`.
- The raw calls in `std.net.os` keep a `sys_` prefix and their Winsock names
  (`sys_wsa_startup`, `sys_closesocket`). Each one calls the runtime's socket layer, so the
  same names work on Linux. The constants are the Winsock values on both systems, and the
  Linux runtime translates the ones that differ.

> Loopback round-trips that combine net, thread and addr are in
> `tests/fixtures/stdlib/net_echo_app.fels` (TCP echo) and `net_udp_app.fels` (UDP echo).
> DNS (`getaddrinfo`) and a small HTTP client are the natural next additions.

## Game & graphics modules

Small, focused modules for 2D games and graphics. `std.math` and `std.color` are
self-contained and need no libm, and `std.rand` is a deterministic PRNG.

### `std.math`

Vectors (`f32`), rectangles, and scalar helpers. Component math wraps the `core::` math
builtins, while `sin`/`cos`/`tan` use a fast polynomial, so there is no libm dependency.

- **Scalars:** `lerp`, `approach`, `signf`, `deg2rad`, `rad2deg`, `wrapf`, `sin`, `cos`, `tan`. Constants `PI`, `TAU`, `DEG2RAD`, `RAD2DEG`.
- **`Vec2`:** `v2`, `v2_zero`, `v2_splat`, `v2_add/sub/mul/scale/neg`, `v2_dot`, `v2_len`, `v2_len2`, `v2_dist`, `v2_dist2`, `v2_normalize`, `v2_lerp`, `v2_perp`, `v2_rotate`, `v2_from_angle`.
- **`Vec3`:** `v3`, `v3_add/sub/scale`, `v3_dot`, `v3_cross`, `v3_len`, `v3_normalize`.
- **`Rect`:** `rect`, `rect_contains`, `rect_overlaps` (AABB), `rect_center`.

### `std.float`

`exp`, `ln` and `pow` for `f64`, written in Fels and good to about 1e-15 relative. A program
needs no math library for them, unlike `core::pow`, which is a call of the C library's `pow`.
For example: `float::pow(1.07, 2.5)`, `float::ln(10.0)`.

### `std.rand`

A deterministic xorshift64\* PRNG. The same seed gives the same sequence, which suits replays
and procedural generation.

- `seed(u64) -> Rng`, `next_u64`, `next_u32`, `next_f32` (\[0,1)), `range_i32(lo,hi)`, `range_f32(lo,hi)`, `chance(p)`, `sign()`.

### `std.color`

32-bit RGBA color.

- `rgb`, `rgba`, `with_alpha`, `gray`, named colors (`white`/`black`/`red`/`green`/`blue`/`yellow`/`orange`/`purple`/`clear`), `lerp`, `to_u32`/`from_u32` (0xRRGGBBAA).

## Containers — `std.vec` and `std.map`

The container library has one defining trait: every container is **region-bound**.
It carries a borrowed `*Arena` and grows by bump-allocating from it, so there are no
per-element frees and no destructors. When the region is `reset`/`deinit`-ed, every
container that lived in it is gone at once. That's the whole memory story, and it's
what makes Fels's containers different from Rust's owning collections or Zig's
allocator-injected ones.

### `std.vec` — `Vec(T)`

A growable array with in-struct methods (UFCS):

```fels
#import std.heap as heap;
#import std.vec as vec;

a := heap::make();
v := vec::make(i32, &a);            // or with_cap / from(T, &a, slice)
v.push(10); v.push(20);
v.insert(1, 15);                    // order-preserving (O(n))
g := v.remove(0);                   // order-preserving removal
s := v.remove_swap(i);             // O(1) unordered removal
for x in v.items() { ... }          // []T view until the next growth

b := heap::make();
w := v.clone_into(&b);             // deep-copy into ANOTHER region (data escapes)
```

- Access: `get`, `set`, `at` (→ `*T`), `last`, `items`. Size: `len`, `cap`, `is_empty`.
- Mutation: `push`, `pop`, `insert`, `remove`, `remove_swap`, `extend`, `reserve`,
  `clear`. Region-moving: `clone_into(into)`.

**Managed vs unmanaged.** `Vec(T)` is *managed*, which means it remembers its region.
`VecUnmanaged(T)` is the *unmanaged* twin. It holds no region, so each growing call takes
the `*Arena` explicitly (`u.push(&a, x)`). Use it when one vector is filled from several
regions or stored in bulk. To copy unmanaged data into the managed API, use
`vec::from(T, a, u.items())`.

### `std.map` — `AutoHashMap(K, V)` and `StrMap(V)`

Open-addressed hash maps with linear probing. They are region-bound too.

```fels
#import std.map as map;

m := map::auto(i32, i32, &a);       // keys: a value type whose bytes are its value
m.put(7, 100); m.put(7, 101);       // overwrite → still one entry
if m.get(7) |v| { ... }             // v == 101 ; get returns ?V
m.contains(7); m.remove(7);

sm := map::strmap(i32, &a);         // keys: []const u8, by content
sm.put("alpha", 1);
sm.get("alpha");                    // hashes + compares the string bytes
```

- **`AutoHashMap(K, V)`** keys a value type whose bytes are its value. It needs no
  `Hash`/`Eq` impl, no derive and no context object. The map hashes the key's **raw
  bytes** and compares them byte-for-byte, which works for integers, plain enums,
  pointers, and structs and arrays of those without padding. The key type must satisfy
  the `map::ByteKey` constraint, so a key that cannot be compared that way is a compile
  error that says why. Such a key is a float (`-0.0` and `0.0` are equal and differ in
  their bytes, and a NaN equals nothing), a slice (a string compares its address, not its
  contents, so key strings with `StrMap`), or a type with bytes no value sets (padding,
  an optional's flag or an enum payload, see `core::has_padding`).
- **`StrMap(V)`** keys `[]const u8`, hashing and comparing the string **contents**. It
  copies each key into the region, so the map owns its keys.
- Both: `put`, `get` (→ `?V`), `contains`, `remove`, `clear`, `len`, `cap`, `is_empty`.

> Fels's approach to hashing: a struct that `#derive(Hash, Eq)`s gets `hash()`/`eq()` for
> free. `AutoHashMap` doesn't even need that, because byte-hashing covers every key whose
> bytes are its value with zero ceremony, and the compiler refuses the others.

## General-purpose modules

### `std.sort`

Sorting slices in place, and binary search in sorted ones. The element type comes first, as
everywhere in std.

```fels
sort::asc(i32, xs);                              // smallest first, by `<`
sort::desc(f64, ys);                             // largest first
sort::by(Person, people, by_age);                // `less(a, b)`: a goes before b
sort::by([]const u8, names, mem::less_bytes);    // text, byte by byte
sort::stable_by(Row, rows, by_date, &scratch);   // equal rows keep their order
sort::is_sorted(i32, xs)                         // true
sort::lower_bound(i32, xs, 42)                   // the first index whose element is not < 42
sort::upper_bound(i32, xs, 42)                   // the first index whose element is > 42
sort::search(i32, xs, 42)                        // ?usize: the first index holding 42
```

`asc`, `desc` and `by` are an introsort: O(n log n) in every case, in place, and not stable.
A run of equal elements costs nothing extra. `stable_asc(T, xs, &arena)` and
`stable_by(T, xs, less, &arena)` are a merge sort that keeps equal elements in their order; the
arena gives them a second slice as long as `xs`. Every search has a `_by` form that takes the
`less` the slice is sorted by (`lower_bound_by`, `upper_bound_by`, `search_by`, `is_sorted_by`).
`less` may be any function value, a closure too.

### `std.path`

Filesystem path strings, with pure manipulation and no I/O. Both `/` and `\` are accepted
as separators, and `join` writes `SEP`, which is `\` on every target. Query functions return
sub-slices and allocate nothing, while builders take an `*Arena`.

```fels
path::basename("a/b/c.txt")            // "c.txt"
path::dirname ("a/b/c.txt")            // "a/b"   ("." when no separator)
path::extension("c.txt")               // ".txt"  (with the dot; "" if none)
path::stem("c.txt")                    // "c"
path::is_absolute("/x")                // true (also "C:\…" and "\unc")
path::has_extension("c.fels", "fels")    // true (leading dot optional)
path::join(&a, "a/b", "c.txt")         // "a/b\c.txt"
path::with_extension(&a, "c.txt", "md")// "c.md"
```

One invariant holds: `basename(p)` == `stem(p)` ++ `extension(p)`.

### `std.time`

Wall-clock time, a monotonic clock, sleeping, and a UTC calendar breakdown, on Windows and
Linux. The clocks come from the platform runtime, which calls kernel32 on Windows and
`clock_gettime` and `nanosleep` on Linux.

```fels
secs := time::unix_seconds();          // i64 seconds since 1970-01-01 UTC
ms   := time::unix_millis();
dt   := time::utc(secs);               // DateTime { year, month, day, hour, minute, second, weekday }

start := time::now();                  // monotonic Instant
time::sleep_ms(16u32);
ns := time::since_nanos(start);        // also since_millis / since_seconds
boot := time::monotonic_millis();      // the same monotonic clock, in milliseconds
```

`utc` is exact for any time ≥ the epoch, using Howard Hinnant's civil-from-days. `weekday`
runs from `0`=Sunday to `6`=Saturday.

**Calendar dates.** A `Date` is a day of the Gregorian calendar, kept as the number of days
since 1970-01-01, so dates compare and subtract as numbers:

```fels
d := time::date(2024i64, 1i64, 31i64) ?? time::today_utc();  // null for a day that does not exist
p := d.parts();                        // DateParts { year, month, day }
w := d.weekday();                      // 0=Sunday … 6=Saturday
e := d.add_months(1i64);               // 2024-02-29: the day stays inside the month
f := d.add_days(-1i64);                // also add_years
n := d.days_until(e);                  // 29
iso := time::parse_date("2024-03-15"); // ?Date
buf: [10]u8 = .{};
text := time::format_date(e, buf[:]);  // "2024-02-29"
```

`is_leap_year(year)` and `days_in_month(year, month)` answer the calendar questions.

### `std.csv`

This module reads CSV text: records of fields between separators, with fields in quotes as
RFC 4180 has them. A quoted field may hold the separator, line breaks and doubled quotes.

```fels
#import std.csv as csv;

sep := csv::guess_separator(text);     // ';' for "Datum;Kurs", ',' for "date,close", or a tab
r := csv::reader(text, sep);
while !r.done() {
    row := r.next(&a) catch err { ... };   // CsvError.unterminated_quote, at line r.line
    // row[0], row[1], ...
}
rows := csv::records(text, 59u8, &a) catch err { ... };   // every record at once
```

The fields are slices of the text. The one exception is a quoted field with doubled quotes,
which is copied into the arena with single ones. Lines end in LF or CRLF. Empty lines are
skipped, and so is a UTF-8 byte order mark at the start, as Excel writes one. `r.line` is
the line the last record started on, which you can use in messages about a row.

### `std.json`

This module reads JSON of any shape. The text becomes a tree of values in an arena, and you
look into that tree. (For JSON that fits a struct of your own, `std.serde` maps it in one
call.)

```fels
#import std.json as json;

doc := json::parse(text, &a) catch err { ... };   // JsonError: unexpected_end, unexpected_byte,
                                                  // bad_number, bad_string, too_deep, trailing_text
quote := doc.get("chart").get("result").at(0);
for t in quote.get("timestamp").items {
    day := t.as_i64() ?? 0i64;
}
close := quote.get("indicators").get("quote").at(0).get("close").at(5).as_f64();   // ?f64
```

A `Value` has a `kind` (`null_value`, `boolean`, `number`, `string`, `array`, `object`).
`get(key)` reads a member of an object, `at(i)` reads an element of an array, and `len()`
counts them. `items` and `keys` are the elements and the members, in the order of the text.
A lookup that finds nothing gives a null value, so a chain needs no checks on the way. In
the same way, `as_f64`, `as_i64`, `as_text` and `as_bool` give null for a value of another
kind. A number keeps the text it was written as next to its `f64` (which is exact for up to
15 digits). That text is there for a decimal type, or for digits an `f64` cannot hold.
`as_i64` is exact for whole numbers of up to 18 digits. Strings are unescaped, and a `\u`
escape (also a surrogate pair) becomes UTF-8. A string without escapes is a slice of the
text. A byte order mark at the start is skipped, and nesting deeper than 512 is refused. The
comptime VM cannot build the values yet (they are structs in an arena).

### `std.crypto`

Hashing and checksums, as pure computation.

```fels
d := crypto::sha256("abc");                     // FIPS 180-4 SHA-256 → Digest
h := crypto::to_hex(&a, d);                      // "ba7816bf8f01cfea…"

buf: [32]u8 = .{};                               // or write into your own buffer
crypto::sha256_into("abc", buf[0..32usize]);

c := crypto::crc32("123456789");                // 0xcbf43926 (IEEE)
k := crypto::fnv1a_64("key");                   // fast non-crypto hash (and fnv1a_32)
```

`sha256`/`sha256_into` match the standard test vectors. It's a software SHA-256. It is fine
for integrity checks, checksums and content addressing, but it is not audited for
adversarial use.

### `std.serde`

Reflection-driven JSON in both directions, with **no per-type code**. One generic serializer
and one generic parser walk the type's `core::type_info` for its *shape* and an `core::any`
for the field *values/slots*. They recurse through nested structs and slices on their own.

```fels
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

- ints of every width, floats (in minimal form: `2.5`, not `2.500000`), `bool`
- `[]const u8`/`[]u8` as JSON strings (with `\"`, `\\`, `\n`, `\t` escaping/unescaping)
- structs, **recursively** (nested structs, string fields)
- slices of scalars (`[]i32`), structs (`[]Point`) **and nested** ones (`[][]i32`), as JSON arrays
- **optionals** (`?T`): `null` for none, else the payload (scalar / string / struct)
- **enums**: the variant name as a JSON string (`"Blue"`)
- on parse, **unknown object keys are skipped**, and missing fields stay zero-initialized

Deserialization constructs the value reflectively. It zero-inits a `result: T`, wraps a
*mutable* `Any` over its address, and writes each parsed field through the real field
address that `any_field_at` hands back. Arrays and strings are allocated in the arena.

This is the "one source, two speeds" design from docs/12. The *structure* comes from
`core::type_info` (a struct's `id` sizes/tags slice and optional-payload elements, with the
alignment derived recursively from the field types). The *bytes* come from `Any`. So adding
a new type needs no changes to the serializer or the parser.

Two things are not covered. Enum *payloads* aren't emitted, only the variant name, because
`TiVariant` carries no payload type. And `?*T` and maps aren't modeled.

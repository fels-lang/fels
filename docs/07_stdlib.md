# Standard Library

Fels's standard library (`std`): minimal, and allocation-free where it can be. 

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

## `std.fmt`
Formatting utilities built on top of `std.io.Writer`.

- `write_padded_left`, `write_padded_right`, `write_padded_center`
- `write_u64_padded`, `write_hex_u64_padded`
- `join_bytes(w: *Writer, items: []const []const u8, sep: []const u8)`

## `std.mem`
Safe typed-memory generic helpers.

- `eql($T: type, a: []const T, b: []const T) -> bool`
- `starts_with`, `ends_with`, `contains`, `index_of`
- `copy($T: type, dest: []T, src: []const T)`
- `fill($T: type, slice: []T, value: T)`
- `swap`, `reverse`

Byte-specialized aliases are provided: `eql_bytes`, `copy_bytes`, `zero`.

## `std.bytes`
Read and write fixed-width integers at an explicit offset in a byte slice, for wire
formats and file headers where the integers sit at known offsets in a stated byte order.

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

- **Names:** `read_<width>_<order>` and `write_<width>_<order>`, with width `u16`, `u32`
  or `u64` and order `le` (little-endian) or `be` (big-endian); plus `read_u8` and
  `write_u8`, which have no order. Reads are `(self: []const u8, off: usize) -> T ! BytesError`;
  writes are `(self: []u8, off: usize, v: T) -> void ! BytesError`. A signed value is the
  unsigned one cast: `read_u16_le(b, 0)? as i16`.
- **Bounds are always checked**, in every build mode (plain slice indexing is checked only
  at `-O0`). An integer that would not lie wholly inside the slice fails with
  `.out_of_bounds`, and then nothing was read or written. The offset can be any `usize`
  (even `usize` max); the check cannot overflow. `BytesError` is its own error set, so to
  return a different one from a parser, handle it with `catch` (`?` needs matching sets).
- **No alignment is assumed.** The integers are assembled from single bytes, so an odd
  offset or a slice that starts mid-buffer is fine, and byte order does not depend on the
  machine.
- **Unchecked access** is `core::unaligned_read(T, ptr)` (little-endian on the supported
  targets), for a bound you have already proven.
- Imported by name (`#import std.bytes.{ read_u32_le };`) a function also reads as a method:
  `packet.read_u32_le(4)?`.

See `tests/fixtures/stdlib/bytes_app.fels`.

## `std.utf16`
UTF-8 ⇄ UTF-16 conversion, in plain Fels with no OS calls, so it behaves the same on
every target. (Windows' `MultiByteToWideChar` / `WideCharToMultiByte` do a related job;
nothing here depends on them, and the test suite checks the two agree on every Unicode
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

- **Representations.** UTF-8 is a `[]const u8`; nothing guarantees a string is valid UTF-8,
  which is why every conversion validates. UTF-16 is a `[]const u16` of code units in the
  machine's own order (no byte-order mark, no serialisation); a character above U+FFFF is a
  surrogate pair.
- **Functions.** Sizing: `utf16_len(src8)` and `utf8_len(src16)` give the exact size of the
  result. Conversion into your buffer: `utf8_to_utf16(src, dst)` and `utf16_to_utf8(src,
  dst)` return the number of units / bytes written. From an arena: `alloc_utf16(a, src)`,
  `alloc_utf16z(a, src)` (one extra unit past the end is `0`, so `.ptr` is a Win32
  `LPCWSTR`; the returned length excludes it) and `alloc_utf8(a, src)`.
- **Errors (`Utf16Error`).** `.invalid_utf8`, `.invalid_utf16`, `.buffer_too_small` and,
  for the arena functions, `.out_of_memory`. Inspect one with `e == .invalid_utf8` in a
  `catch`.
- **Malformed input is an error and is never repaired**; there is no replacement
  character. UTF-8 is rejected for: a stray continuation byte, `C0`/`C1`/`F5`–`FF`, a
  truncated sequence, a non-continuation where one is required, an overlong encoding,
  an encoded surrogate (`ED A0`–`BF`), and anything above U+10FFFF. UTF-16 is rejected for
  a high surrogate not followed by a low one and for a low surrogate with no high one
  before it. U+0000 is an ordinary character.
- **Capacity is explicit.** A conversion validates and counts first, then checks the
  destination, then writes. If the input is malformed or `dst` is too small it fails and
  **`dst` is not modified**. A longer-than-needed `dst` keeps its extra units as they were.
  The arena functions allocate exactly the result (plus the terminator for `alloc_utf16z`)
  and the arena owns it; nothing is freed.

See `tests/fixtures/stdlib/utf16_app.fels` (hand-picked and exhaustive cases) and
`utf16_win_app.fels` (agreement with the Windows APIs).

## `std.fs`
Minimal synchronous file I/O, on Windows and Linux.

- `open(path)`: Open existing file for reading
- `create(path)`: Create/truncate file for writing
- `append(path)`: Open for appending
- `delete(path)`: Remove a file
- `exists(path)`: Check file existence
- `make_dir(path)`: Make a folder (one that is there already is fine); `make_dirs(path)` makes
  the folders above it too; `remove_dir(path)` removes an empty folder
- Returns a `File` struct which implements both `Reader` and `Writer`.
- Paths are UTF-8, as all Fels text (on Windows the runtime turns them into the UTF-16 of the
  `*W` functions), up to 1023 bytes; `dir_next` gives names in UTF-8 too.

## `std.process`
Process management, on Windows and Linux.

- `spawn(cmd)`: Spawn a child process (returns `Child`)
- `wait(child)`, `try_wait(child)`, `kill(child)`, `release(child)`
- `current_pid()`
- `get_env`, `set_env`, `unset_env`
- `command_line`: the command line as one text
- `args(&a)`: the arguments, the program first. On Windows they are split from the command
  line as the C runtime splits it (`split_command_line(line, &a)` does that for any line:
  quotes keep spaces, `\"` is a quote); on Linux they are as the kernel passed them.

## `std.ptr`
Pointer manipulation and conversions (requires `unsafe` in some contexts).

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
Atomic operations over shared memory — the foundation for lock-free code and
synchronising threads. Each operation acts on a pointer to the value and **infers
the element type** (no explicit `$T`). Read-modify-write helpers return the
**previous** value, like C/LLVM. Helpers default to **sequentially consistent**
ordering; for finer control call the `core::atomic_*` builtins with an ordering
constant (`Relaxed`/`Acquire`/`Release`/`AcqRel`/`SeqCst`).

```fels
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

```fels
#import std.atomics;
#import std.atomics.{Atomic};         // bring the type name into scope

counter: Atomic(u32) = .{ 0u32 };     // or: counter := Atomic::make(0u32);
old := counter.add(1u32);             // returns the previous value
if counter.cas(1u32, 100u32) { ... }  // compare-and-swap
n := counter.get();
```

Methods: `get`/`set`, `get_acquire`/`set_release`, `exchange`, `cas`/`cas_value`,
`add`/`sub`/`mul`/`div` (numeric), `max`/`min`, `and`/`or`/`xor`/`nand` (integer) —
each carrying the same compile-time contract as its free-function counterpart.

> Atomic increments across threads lose nothing under contention — that's the whole
> point (a plain `+= 1` would race). See `tests/fixtures/stdlib/atomics_thread_app.fels`,
> and `atomic_cell_app.fels` for the `Atomic(T)` method API.

## `std.thread`
Native OS threads and structured helpers. fels favours *real threads* over async/await
— no function colouring, no hidden executor, no heap-allocated coroutine frames; a
thread is a stack plus an entry point. An entry has the shape `fn(*void) -> u32`: it
receives a single context pointer and returns an exit code.

Because fels's ordinary function value is a fat `{fn, env}` closure that a C ABI can't
call, hand the entry over as **`core::fn_ptr(worker)`** — the raw thin function
pointer. The context pointer you pass must outlive the thread (join before its data
leaves scope, or put the data on a long-lived arena).

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

- **`Thread`** (methods): `join() -> u32` (waits, returns exit code, closes handle),
  `detach()` (fire-and-forget), `is_running()` (non-blocking poll), `ok()`.
- **`spawn(entry, arg) -> Thread`** — start a thread; `entry` is `core::fn_ptr(fn)`.
- **Helpers:** `current_id()`, `sleep(ms)`, `yield_now()`, `cpu_count()`.
- **`ThreadGroup`** — structured fan-out: `spawn(entry, arg)` adds a thread,
  `join_all()` blocks until the whole batch finishes (the batch can't outlive the
  call site). `thread::group()` makes an empty one.

```fels
g := thread::group();
i: usize = 0usize;
while i < thread::cpu_count() as usize { g.spawn(core::fn_ptr(worker), cp); i += 1usize; }
g.join_all();                    // wait for all
```

> Locks, waiting and a blocking queue are in [`std.sync`](#stdsync); counters and flags
> need only `std.atomics`. See `tests/fixtures/stdlib/thread_app.fels`.

## `std.sync`
Mutual exclusion and waiting between threads, on the operating system's own primitives: a
thread that cannot proceed sleeps in the kernel instead of polling in a loop. On Windows a `Mutex` is a
slim reader/writer lock (`SRWLOCK`) used exclusively and a `CondVar` a `CONDITION_VARIABLE`;
on Linux they are built on `futex(2)`. Both are one machine word kept in your own struct, so
there is no allocation, no initialisation call and nothing to destroy: **all zero bits is the
unlocked state**, which makes `m: Mutex = .{};` correct as a local, as a struct field and as a
global in static storage.

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

- **`Mutex`** — `lock()` sleeps until it holds the lock; `try_lock() -> bool` takes it only if
  it is free right now; `unlock()` releases it. Pair `lock()` with `defer m.unlock();` to
  release on every exit from a function.
- **`CondVar`** — `wait(&m)` releases `m`, sleeps, and holds `m` again when it returns.
  `wait_timeout(&m, ms) -> bool` gives up after `ms` milliseconds (0xFFFFFFFF means never) and
  returns `false` when the time ran out. `signal()` wakes one waiter, `broadcast()` wakes all;
  either may be called with or without the lock held.
- **A wait can return early.** A thread may be woken by nothing (a *spurious wake-up*, which
  both operating systems allow), and a `signal()` sent while nobody waits is forgotten. That is
  why the condition lives in data guarded by the mutex and every wait sits in a
  `while !condition { … }` loop, as above. `wait_timeout` returning `true` means "woken", not
  "the condition holds".
- **Rules.** Share a lock by address, and do not copy one that is in use. A `Mutex` is not
  recursive — locking it again from the thread that holds it deadlocks — and unlocking one the
  thread does not hold is undefined. Nothing is fair, and there is no ownership or poisoning
  check. Do not move or free a lock while a thread holds it or sleeps on it: join the threads
  first.

**`Queue(T)`** is a bounded blocking FIFO for any number of producers and consumers. It is
**bounded** by design: it owns no memory — you hand it the storage, which fixes the capacity —
so nothing is allocated behind your back, a producer that outruns its consumers waits instead
of exhausting memory, and there is no allocator to share between threads.

```fels
#import std.sync;

buf: [64]i32 = .{};
q := sync::make_queue(i32, buf[:]);     // capacity 64; `buf` must outlive every user

q.push(7);                              // sleeps while the queue is full; false once closed
v := q.pop() ?? -1;                     // sleeps while it is empty; null once closed and drained
```

- `push(item) -> bool`, `try_push(item) -> bool` (false if full, closed or capacity 0),
  `pop() -> ?T`, `try_pop() -> ?T` (null if empty), `len()`, `capacity()`, `is_closed()`.
- **Shutdown.** `close()` ends the queue and wakes everyone blocked on it. After it, `push` and
  `try_push` return `false`; items already queued can still be popped, and when they run out
  `pop` returns `null`. So a pipeline stops like this: the producers finish, the owner calls
  `close()`, the consumers drain the queue and see `null`, the owner joins them, and only then
  releases the storage. `close()` may be called again harmlessly.
- **Destruction.** A `Queue` holds no resource: there is no `deinit`. What must not happen is
  freeing or moving the storage, or the `Queue` itself, while a thread is still inside a call —
  hence "join, then release".
- Items leave the queue in the order they went in (with several consumers, the order in which
  they finish is up to the scheduler). A `Queue` over empty storage can hold nothing: `push`
  fails, `pop` waits for `close()`.

There is no reader/writer lock, semaphore, barrier, one-shot or unbounded channel yet. See
`tests/fixtures/stdlib/sync_app.fels` — contention with exact totals, a two-thread hand-off that
must alternate strictly, a broadcast, timed waits, and many producers against many consumers with
every item delivered exactly once.

## `std.com` — COM and Windows Runtime types
The data types of COM and the Windows Runtime, with no operating-system call, so it compiles for
every target: `Guid`, `HRESULT`, `IUnknown` and `IInspectable` with their vtables, and a reference
counter for objects you implement. [`std.winrt`](#stdwinrt--calling-com-and-the-windows-runtime-windows-only) is the part that calls Windows.

Every layout, GUID and constant was compared with the official Windows SDK headers
(`guiddef.h`, `winerror.h`, `unknwn.h`, `inspectable.h`, `activation.h`) by compiling them with
clang for `x86_64-pc-windows-msvc` and printing `sizeof`, `offsetof`, each interface's `__uuidof`
and each constant; `#assert`s in the module pin the layouts, so a wrong offset is a build error.

- **`Guid`** — 16 bytes, aligned to 4: `data1: u32`, `data2: u16`, `data3: u16`, `data4: [8]u8`
  (an IID and a CLSID are GUIDs). `eq(&other)`, `is_null()`, `format(buf) -> usize` (writes
  `{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}` in upper case; `buf` needs `GUID_TEXT_LEN` = 38 bytes,
  else `.buffer_too_small`), and `parse_guid(text)` — exactly 8-4-4-4-12 hex digits in either case,
  with the braces or without; anything else is `.invalid_format`. The well-known ids are globals —
  `IID_IUnknown`, `IID_IInspectable`, `IID_IAgileObject`, `IID_IActivationFactory` — passed by
  address (`&com::IID_IUnknown`). Treat them as constants: the language has no read-only aggregate
  yet, so nothing stops a write.
- **HRESULT** is an `i32` (`Hresult`): negative is failure, zero or more is success (`S_FALSE` = 1
  is a success that means "no"). The `winerror.h` codes you meet are constants (`S_OK`, `E_FAIL`,
  `E_NOINTERFACE`, `E_INVALIDARG`, `RPC_E_CHANGED_MODE`, `REGDB_E_CLASSNOTREG`, …);
  `succeeded(hr)`, `failed(hr)`, `facility(hr)`, `code(hr)` and `from_win32(err)`
  (`HRESULT_FROM_WIN32`) take one apart or build one.
- **From an HRESULT to an error.** `check(hr)` succeeds on any success code and fails with
  `ComError` otherwise: the common codes have their own names (`.no_interface`, `.invalid_arg`,
  `.out_of_memory`, `.class_not_registered`, `.changed_mode`, …) and any other failure is `.other`,
  which no longer says which code it was. Keep the HRESULT if you need it.
- **From an error back to an HRESULT** is written where the error is caught, because an error is
  not yet a value another function can take:

  ```fels
  read_header(self) catch e {
      if e == .no_interface { return E_NOINTERFACE; }
      return E_FAIL;
  };
  return S_OK;
  ```
- **`IUnknown`** `{ vtbl }` and its vtable `{ query_interface, add_ref, release }`, with the three
  methods on the struct; **`IInspectable`** (the base of every Windows Runtime interface) adds
  `get_iids`, `get_runtime_class_name` and `get_trust_level`; **`IActivationFactory`** adds
  `activate_instance`. A COM method is called through the table with the interface pointer first —
  `p.vtbl.release(p)` — and on x86-64 Windows there is one calling convention, so any Fels
  function with matching parameter and result types fits a table slot.
- **`RefCount`** — one atomic 32-bit counter for an object you implement: `new_refcount()` starts
  at 1 (the creator's reference), `add()` and `release()` return the new count, and a `release()`
  that returns 0 means the object is unreferenced and yours to free.

**Ownership is by reference count and nothing else owns anything.** An interface pointer a function
hands you (an out-parameter, or what `query_interface` returns) carries one reference that is
yours to release exactly once; a pointer you are only lent is not yours to release, and you
`add_ref` it to keep it; releasing the last reference destroys the object and any later use is a
crash. The counts that `add_ref` and `release` return are for diagnostics — never branch on them.

**Declaring an interface** is listing its vtable in header order with `this` first, then
asserting the offsets against the header. **Implementing one** is a struct whose first field is the
vtable pointer, plus a vtable that is static data — a global initialised with the functions, no
table built at run time:

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
The part of the COM / Windows Runtime story that calls Windows: starting COM and the Runtime on a
thread, creating objects and activating runtime classes, and `HSTRING`. It is thin on purpose —
each function that mirrors an OS call keeps the call's shape and returns its HRESULT unchanged
(pass it to `com::check`), the few that only return a status (`co_initialize`, `ro_initialize`) or
have one natural result (`activation_factory`, `new_guid`) are fallible, and nothing runs on its
own: no hidden initialisation, no thread-local state. A program that imports it for another target
fails to link, as for any missing Win32 function. The COM entry points come from `ole32.dll` and
the Runtime ones from `combase.dll`; the Windows SDK has no `combase.lib` (it ships those in
`runtimeobject.lib`), so the linker driver hands LLD that library, and `felsld` imports the DLL
directly.

- **Apartments.** `co_initialize(mode)` / `ro_initialize(kind)` apply to the calling thread and each
  success - including one that returned `S_FALSE`, "already initialised" - is paired with one
  `co_uninitialize()` / `ro_uninitialize()` on the same thread. Initialising a thread the other way
  fails with `.changed_mode`. Use the multithreaded kinds (`CO_MULTITHREADED`, `RO_MULTITHREADED`)
  unless the thread pumps a message loop.
- **Creating objects.** `co_create_instance(&clsid, CLSCTX_INPROC_SERVER, &iid, &out)` is
  `CoCreateInstance` (HRESULT back, `*out` an owned interface pointer). `activation_factory(class_id,
  &iid)` is `RoGetActivationFactory`: the class name as an HSTRING handle (`.h`), an owned `*IUnknown`
  back to cast to the factory interface, `.class_not_registered` if there is no such class.
  `activate_instance(class_id)` is `RoActivateInstance`. `new_guid()` is `CoCreateGuid`;
  `co_task_mem_free(p)` frees what the OS allocated for you with the COM task allocator, like the
  array `IInspectable.get_iids` returns.
- **`HString`** — an owned `HSTRING`: `.h` is the one-pointer handle to pass to the OS (the null
  handle is the empty string). `hstring(units)` copies UTF-16 in (`WindowsCreateString`),
  `hstring_from_utf8(text, scratch)` converts through your `[]u16` scratch buffer first, `release()`
  deletes it (idempotent), `duplicate()`, `len()`, `is_empty()`, `units()` (a borrowed view, valid
  until `release()`), `eq(&other)` (case-sensitive) and `to_utf8(out)`. An HSTRING may hold zeros
  and unpaired surrogates; `to_utf8` refuses the latter with `.invalid_utf16`.
- **`HStringRef`** — a borrowed `HSTRING` over a buffer you already hold (no allocation, nothing to
  release), the cheap way to pass a class name. `init(z)` takes the UTF-16 *with its terminating
  zero*; the struct must not move after `init`, and the buffer must outlive every use of `.h`.

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

`tests/fixtures/stdlib/winrt_app.fels` goes further against the real system: GUID text and parsing
compared with `StringFromGUID2` / `IIDFromString`; an HSTRING through every operation; the OS's
in-memory `IStream` called through a vtable declared from `objidl.h`; a COM object written in
Fels that the OS calls back (`IStream::CopyTo` writes into it); and `Windows.Foundation.Uri`
activated and read through its interfaces, with the reference counts checked.

What it does not do: no events, delegates or async, no generated projection of a runtime class (you
declare the interfaces you call), no smart pointer — a release is a call you write, with `defer` —
and no marshalling across apartments.

## `std.net` — networking
TCP and UDP over Winsock2, layered across a subdirectory module so each piece stays
small and focused. From the bottom up:

| Module | What it gives you |
| --- | --- |
| `std.net.os` | Raw `ws2_32` `#extern` bindings, protocol constants, the `sockaddr_in` wire struct, the shared `NetError`, and `addr ⇄ wire` conversions. The foundation; reach for it directly only for an option the upper layers don't expose. |
| `std.net.addr` | `IpV4` / `SocketAddr` — parse, format, classify (`is_loopback`/`is_unspecified`), `to_net`/`from_net`, `#derive(Eq)`. |
| `std.net.socket` | `Socket`: the typed handle and the options shared by every protocol (`set_recv_timeout`/`set_send_timeout`, `set_reuse_addr`, `set_broadcast`, `set_nonblocking`, `shutdown`, `bind_to`, `local_addr`). |
| `std.net.tcp` | `TcpStream` / `TcpListener` — streams plus `send_all` / `recv_exact`, `set_nodelay`, `accept` returning the peer address. |
| `std.net.udp` | `UdpSocket` — datagrams (`send_to` / `recv_from`) and the connected `connect`+`send`/`recv` shortcut. |
| `std.net` | A thin facade re-exporting the lifecycle (`init` / `shutdown` / `last_error`) and the constructors (`connect` / `listen` / `udp_bind`). |

It leans on the newer language features throughout — in-struct methods, `#derive`,
and `!`-fallible returns. Every layer fails with the one shared `os::NetError`.

**Addresses** (`std.net.addr`) — `IpV4` (`#derive(Eq)` + a hand-written `format`
rendering a dotted quad) and `SocketAddr` (whose derived `Eq` recurses into `IpV4.eq`):
```fels
#import std.net.addr as addr;
ip  := addr::parse("127.0.0.1") catch e { ... };   // fallible
sa  := addr::socket_addr(addr::localhost(), 8080u16);
sa.format(&sb);                                      // "127.0.0.1:8080"
```

**TCP** — `init()` once, then `connect(addr)` / `listen(addr)`:
```fels
#import std.net as net;
#import std.net.addr as addr;
#import std.net.tcp as tcp;          // for the TcpStream / TcpListener types

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

**UDP** — connectionless datagrams, or `connect` to pin a default peer:
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
- Types live in their submodule (`tcp::TcpStream`, `udp::UdpSocket`, …) because the
  language doesn't re-export a type across modules; the facade hands those types
  back, so you only need the submodule import for a type annotation.
- The raw Winsock bindings keep a `sys_` prefix; the `#extern` 2nd arg is the real
  link symbol, so the fels name is free to differ from the C name.

> Loopback round-trips combining net + thread + addr are in
> `tests/fixtures/stdlib/net_echo_app.fels` (TCP echo) and `net_udp_app.fels` (UDP echo).
> DNS (`getaddrinfo`) and a small HTTP client are the natural next additions.

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

### `std.float`

`exp`, `ln` and `pow` for `f64`, written in Fels and good to about 1e-15 relative: a program
needs no math library for them, as it does for `core::pow` (a call of the C library's `pow`).
`float::pow(1.07, 2.5)`, `float::ln(10.0)`.

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

```fels
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

## Containers — `std.vec` and `std.map`

The container library has one defining trait: every container is **region-bound**.
It carries a borrowed `*Arena` and grows by bump-allocating from it — there are no
per-element frees and no destructors. When the region is `reset`/`deinit`-ed, every
container that lived in it is gone at once. That's the whole memory story, and it's
what makes fels's containers different from Rust's owning collections or Zig's
allocator-injected ones.

### `std.vec` — `Vec(T)`

A growable array with in-struct methods (UFCS), the successor to `std.list`:

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

**Managed vs unmanaged.** `Vec(T)` is *managed* — it remembers its region.
`VecUnmanaged(T)` is the *unmanaged* twin: it holds no region, and each growing call
takes the `*Arena` explicitly (`u.push(&a, x)`). Use it when one vector is filled
from several regions or stored in bulk. Copy unmanaged data into the managed API
with `vec::from(T, a, u.items())`.

### `std.map` — `AutoHashMap(K, V)` and `StrMap(V)`

Open-addressed (linear-probing) hash maps, also region-bound.

```fels
#import std.map as map;

m := map::auto(i32, i32, &a);       // keys: ANY value type
m.put(7, 100); m.put(7, 101);       // overwrite → still one entry
if m.get(7) |v| { ... }             // v == 101 ; get returns ?V
m.contains(7); m.remove(7);

sm := map::strmap(i32, &a);         // keys: []const u8, by content
sm.put("alpha", 1);
sm.get("alpha");                    // hashes + compares the string bytes
```

- **`AutoHashMap(K, V)`** keys *any value type* — no `Hash`/`Eq` impl, no derive,
  no context object. The map hashes the key's **raw bytes** and compares them
  byte-for-byte. Ideal for integers, enums, points, small POD structs. It is *not*
  for keys containing pointers/slices (a string, a `Vec`) or structs with
  uninitialised padding — use `StrMap` or a hand-rolled map there.
- **`StrMap(V)`** keys `[]const u8`, hashing and comparing the string **contents**
  (and copying each key into the region so the map owns its keys).
- Both: `put`, `get` (→ `?V`), `contains`, `remove`, `clear`, `len`, `cap`, `is_empty`.

> fels's hashing identity: a struct that `#derive(Hash, Eq)`s gets `hash()`/`eq()` for
> free — but `AutoHashMap` doesn't even need that, because byte-hashing covers every
> POD key with zero ceremony. Drop a value in and it's a key.

## General-purpose modules

### `std.path`

Filesystem path strings — pure manipulation, no I/O. Both `/` and `\` are accepted
as separators; `join` writes the platform `SEP`. Query functions return sub-slices
(no allocation); builders take an `*Arena`.

```fels
path::basename("a/b/c.txt")            // "c.txt"
path::dirname ("a/b/c.txt")            // "a/b"   ("." when no separator)
path::extension("c.txt")               // ".txt"  (with the dot; "" if none)
path::stem("c.txt")                    // "c"
path::is_absolute("/x")                // true (also "C:\…" and "\unc")
path::has_extension("c.fels", "sk")      // true (leading dot optional)
path::join(&a, "a/b", "c.txt")         // "a/b\c.txt"
path::with_extension(&a, "c.txt", "md")// "c.md"
```

Invariant: `basename(p)` == `stem(p)` ++ `extension(p)`.

### `std.time`

Wall-clock time, a monotonic clock, sleeping, and a UTC calendar breakdown
(Windows backend, kernel32).

```fels
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

Reading CSV text: records of fields between separators, with fields in quotes as RFC 4180 has
them (a quoted field may hold the separator, line breaks and doubled quotes).

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

The fields are slices of the text, except a quoted field with doubled quotes, which is copied
into the arena with single ones. Lines end in LF or CRLF; empty lines are skipped, and so is a
UTF-8 byte order mark at the start, as Excel writes one. `r.line` is the line the last record
started on, for messages about a row.

### `std.json`

Reading JSON of any shape: the text becomes a tree of values in an arena, to look into. (For
JSON that fits a struct of your own, `std.serde` maps it in one call.)

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

A `Value` has a `kind` (`null_value`, `boolean`, `number`, `string`, `array`, `object`);
`get(key)` reads a member of an object, `at(i)` an element of an array and `len()` counts them;
`items` and `keys` are the elements and the members (in the order of the text). A lookup that
finds nothing gives a null value, so a chain needs no checks on the way, and `as_f64`,
`as_i64`, `as_text` and `as_bool` give null for a value of another kind. A number keeps the
text it was written as next to its `f64` (exact for up to 15 digits), for a decimal type or
for digits an `f64` cannot hold; `as_i64` is exact for whole numbers of up to 18 digits.
Strings are unescaped, a `\u` escape (also a surrogate pair) as UTF-8; one without escapes is a
slice of the text. A byte order mark at the start is skipped; nesting deeper than 512 is
refused. The comptime VM cannot build the values yet (they are structs in an arena).

### `std.crypto`

Hashing and checksums — pure computation.

```fels
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
from `core::type_info` (a struct's `id` sizes/tags slice + optional-payload elements; alignment is
derived recursively from field types) and the *bytes* come from `Any`, so adding a new type
needs zero serializer/parser changes.

Limit: enum *payloads* aren't emitted (only the variant name — `TiVariant` carries no payload
type), and `?*T` / maps aren't modeled.

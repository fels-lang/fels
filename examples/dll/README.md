# dll — a shared library with exported symbols

Proves the plumbing a native plugin needs: `b.shared` emits a real DLL, `#export`
puts functions **and data** in its export table under the names you gave, and a
foreign process can resolve them and use them.

```
gabbro build
```

Verified with `llvm-readobj --coff-exports`:

```
Export { Ordinal: 1  Name: gab_add      }
Export { Ordinal: 2  Name: gab_calls    }
Export { Ordinal: 3  Name: gab_entry    }
Export { Ordinal: 4  Name: gab_version  }
```

and by loading it from an unrelated process:

```python
import ctypes

class Version(ctypes.Structure):
    _fields_ = [("major", ctypes.c_uint32), ("minor", ctypes.c_uint32), ("revision", ctypes.c_uint32)]

class Entry(ctypes.Structure):
    _fields_ = [("version", Version),
                ("init",   ctypes.CFUNCTYPE(ctypes.c_uint32, ctypes.c_uint32)),
                ("scale",  ctypes.CFUNCTYPE(ctypes.c_int32, ctypes.c_int32)),
                ("deinit", ctypes.CFUNCTYPE(None))]

dll = ctypes.CDLL(r"...\gabdll.dll")
dll.gab_add.argtypes = [ctypes.c_int32, ctypes.c_int32]
dll.gab_add.restype  = ctypes.c_int32
dll.gab_add(20, 22)                           # 42

entry = Entry.in_dll(dll, "gab_entry")        # a struct, read straight out of the image
entry.version.major, entry.version.minor      # 1, 2
entry.scale(14)                               # 42 — through a function pointer in the struct
ctypes.c_int32.in_dll(dll, "gab_calls").value # 1 — a global the library wrote and the host reads
```

## What a plugin entry point needs

A CLAP or VST3 plugin's entry point is an exported **data** symbol —
`extern const clap_plugin_entry_t clap_entry;` — a static struct of version numbers and
function pointers that the host reads and calls through. `gab_entry` is that shape:

```gabbro
#export("gab_entry")
ENTRY: PluginEntry = .{ .{ 1u32, 2u32, 0u32 }, plugin_init, plugin_scale, plugin_deinit };
```

The struct is laid out in the image when the library is built. The function addresses in it
are fixed by the linker, and the loader adjusts them to wherever the DLL lands (the DLL
carries a base-relocation table); nothing in the library runs at load time to build it. See
"Static aggregates" in [docs/01_syntax.md](../../docs/01_syntax.md) for what a global's
initializer may be, and "Exporting data" in [docs/11_c_interop.md](../../docs/11_c_interop.md).

Still on the plugin author: the field list and ABI of the real `clap_plugin_entry_t` (write
the struct to match the header, and check it with `#assert(core::sizeof(...))` and
`core::offset_of`), and the factory objects the entry hands out.

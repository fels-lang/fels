# Build system showcase

A tour of the `std.build` API. Run these from this directory:

```sh
k2 build            # build the default artifact (app) into bin/
k2 build run        # build, then run it
k2 build --list     # list artifacts and steps
k2 build -Dtrace    # enable the `trace` build option (defines TRACE=1)
k2 build --release  # force release optimization
k2 build plugin     # build a specific artifact (the shared library)
```

[build.k2](build.k2) demonstrates: a workspace + `out_root`, a GUI executable
(`windowed()`), optimization levels, stack size, version/description/install
metadata, linking + raw linker flags, a configurable `-D` build option, a
companion shared library, a run step, a default, and the build `summary()`.

See [docs/10_build_system.md](../../docs/10_build_system.md) for the full reference.

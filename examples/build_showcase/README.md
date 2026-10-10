# Build system showcase

A tour of the `std.build` API. Run these from this directory:

```sh
fels build                     # the default step `all`: the app, the plugin and the assets
fels build run                 # build, then run the app
fels build --list              # artifacts, steps and options
fels build -Dtrace -Dthreads=8 -Dgreeting=Hi
fels build -Dmode=fast         # optimize the app for speed
fels build install             # copy the app, its DLL and the assets to dist/
fels build clean               # remove what the build made
fels build plugin              # build one artifact (the shared library)
```

[build.fels](build.fels) shows:

- typed build options (`option_bool`, `option_int`, `option_string`, `option_choice`)
- a static library the app links with `link_artifact`, built first
- a shared library, installed next to the app
- constants for the program (`define`, `define_bool`, `define_int`), which
  [src/main.fels](src/main.fels) reads with `#import build_options;`
- steps: copying the assets, an `all` step as the default, a run step with a working
  directory, and a clean step
- `fels build install` with `install()` and `install_dir`
- the workspace, `out_root`, the version and description, and the build `summary()`

See [docs/10_build_system.md](../../docs/10_build_system.md) for the full reference.

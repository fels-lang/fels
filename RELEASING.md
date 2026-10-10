# Releasing gabbro

gabbro ships as a **slim, relocatable core archive**: `gabbro.exe` plus `LLVM-C.dll`
(codegen) and `gabbrolld.dll` (the in-process COFF linker — no spawned `lld-link.exe`),
and the standard library, laid out so the binary finds everything relative to
itself (see Phase 0 — the runtime resolves `std/` from the exe's directory).
Download, extract, run `bin/gabbro`. No install step, and no separate LLVM needed to
*use* the compiler.

The core does **not** bundle `libclang` (81 MB) — `gabbro bindgen` loads it on demand
and ships as a separate optional component (`gabbro-bindgen-<ver>-<target>.zip`). See
[docs/19_distribution.md](docs/19_distribution.md) for the full model.

## LLVM in CI

The workflows download the official LLVM release for Windows from llvm.org
(`clang+llvm-<version>-x86_64-pc-windows-msvc.tar.xz`, about 820 MB) with the
`.github/actions/setup-llvm` action. It keeps only the files the build, the tests and
`package.ps1` use (about 690 MB unpacked instead of 3.9 GB) and caches them, so later
runs skip the download. No secret or repo variable is needed.

To move to a new LLVM, change the `version` default in `.github/actions/setup-llvm/action.yml`.
If the build starts to need another LLVM file, add it to the list in that action and bump
the `files` number in its cache key. `mlugg/setup-zig@v2` caches the Zig cache of each job.

## Workflows

- **`ci.yml`** — every push/PR. `check` (no LLVM, always) + `full` (LLVM codegen
  + exe-integration tests).
- **`nightly.yml`** — every push to `main`. Builds + refreshes a rolling
  `nightly` pre-release pointing at the latest commit.
- **`release.yml`** — on a `v*` tag. Builds + publishes a GitHub Release.

## Cutting a release

The **tag is the source of truth** for the version. Bump `.version` in
`build.zig.zon` to match, then tag:

```sh
git tag v0.1.0-beta.1 && git push origin v0.1.0-beta.1   # → pre-release
git tag v0.1.0        && git push origin v0.1.0           # → stable release
```

- The release notes are the section of `CHANGELOG.md` for that version (`## 0.3.1 ...`), so
  rename `## Unreleased` to the version before tagging. A pre-release without its own section
  uses `## Unreleased`.
- The workflow smoke tests the archive (builds and runs a small program) before it publishes.
- To try the whole build without publishing, run the Release workflow by hand (Actions >
  Release > Run workflow). The archives are kept as workflow artifacts.
- A tag with a SemVer pre-release part (anything after `-`) publishes as a GitHub
  **pre-release**; a bare `vMAJOR.MINOR.PATCH` publishes as a full release.
- The reported version (and release name) carries `+<git-sha>` build metadata for
  pre-releases — e.g. `gabbro 0.1.0-beta.1+ab6e587` — while the asset filename stays
  URL-friendly (`gabbro-0.1.0-beta.1-x86_64-windows.zip`).
- `gabbro version` always reflects the exact build (`build.zig.zon` + `+<git-sha>` for
  dev/pre-release builds; overridable with `-Dversion=…`).

## Packaging locally

```pwsh
pwsh scripts/package.ps1 -LlvmPath <your-llvm-dir> [-Version 0.1.0-beta.1]
# → dist/gabbro-<version>-x86_64-windows.zip              (slim core, in-process LLD)
# → dist/gabbro-bindgen-<version>-x86_64-windows.zip      (optional libclang component)
# → dist/gabbro-linux-cross-<version>-x86_64-windows.zip  (optional ld.lld for --target linux)
```

The core archive carries `install.ps1` (Windows); the Linux/macOS archives carry
`install.sh`. Both copy the layout to a stable prefix and wire up `PATH` +
`GABBRO_HOME`. The release and nightly workflows publish all three archives as assets.

> Heads-up: an aggressive behavioral AV (e.g. G DATA DeepRay) may quarantine the
> freshly built `gabbro.exe` or kill the packaging process — a compiler emitting fresh
> unsigned executables looks like a dropper. Add a build-folder / process
> exception, or code-sign the release binaries.

## Known gap

The released `gabbro.exe` still uses a **build-baked Windows SDK lib path** (for the
`kernel32.lib` it hands to programs it links). On a machine without that exact SDK
version, linking *user programs* needs `-Dwindows-sdk-lib-path` at build time or a
matching SDK present. Making the SDK relocatable (bundle the import lib / resolve
beside the exe) is the next packaging step.

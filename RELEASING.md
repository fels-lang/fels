# Releasing k2

k2 ships as a **self-contained, relocatable archive**: `k2.exe` plus the LLVM/clang
DLLs, the `lld` linkers, and the standard library, laid out so the binary finds
everything relative to itself (see Phase 0 — the runtime resolves `std/` and the
linker from the exe's directory). Download, extract, run `bin/k2`. No install
step, and no separate LLVM needed to *use* the compiler.

## One-time CI setup

The build needs an LLVM prebuilt that ships **LLVM-C + libclang + headers** (the
same one used locally). CI can't fetch that automatically, so configure:

| Kind | Name | Value |
| --- | --- | --- |
| Repo **secret** | `LLVM_URL` | A downloadable archive of your LLVM (`.7z`/`.zip`) |
| Repo **variable** | `LLVM_AVAILABLE` | `true` (gates the LLVM-dependent jobs on) |
| Repo **variable** | `LLVM_VERSION` | optional — bump to invalidate the LLVM cache |

Until `LLVM_AVAILABLE=true`, the LLVM jobs are skipped and the fast `check` lane
(build + the LLVM-independent suite, incl. the 74-case VM corpus) still gates
every PR. Adjust the extractor in the workflows if your archive isn't `.7z`.

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

- A tag with a SemVer pre-release part (anything after `-`) publishes as a GitHub
  **pre-release**; a bare `vMAJOR.MINOR.PATCH` publishes as a full release.
- The reported version (and release name) carries `+<git-sha>` build metadata for
  pre-releases — e.g. `k2 0.1.0-beta.1+ab6e587` — while the asset filename stays
  URL-friendly (`k2-0.1.0-beta.1-x86_64-windows.zip`).
- `k2 version` always reflects the exact build (`build.zig.zon` + `+<git-sha>` for
  dev/pre-release builds; overridable with `-Dversion=…`).

## Packaging locally

```pwsh
pwsh scripts/package.ps1 -LlvmPath <your-llvm-dir> [-Version 0.1.0-beta.1]
# → dist/k2-<version>-x86_64-windows.zip
```

## Known gap

The released `k2.exe` still uses a **build-baked Windows SDK lib path** (for the
`kernel32.lib` it hands to programs it links). On a machine without that exact SDK
version, linking *user programs* needs `-Dwindows-sdk-lib-path` at build time or a
matching SDK present. Making the SDK relocatable (bundle the import lib / resolve
beside the exe) is the next packaging step.

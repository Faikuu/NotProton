# Free Wine runtime with in-app download

## Goal

A user without CrossOver can set up NotProton from the Status pane. One button downloads a
free, open-source Wine, verifies it, patches it and registers it as a Steam compatibility
tool. CrossOver support is unchanged.

## Scope

In scope:

- One pinned runtime: Gcenx `wine-devel` 11.15 (`wine-devel-11.15-osx64.tar.xz`), x86_64,
  run under Rosetta. 11.15 is the stock Wine vintage CrossOver's runtime is built from, and
  the `lsteamclient` and `steam-shim` binaries in the bridge are built against it. A
  different vintage speaks a different wineserver protocol (see `bridge/setup-wine-tree.sh`).
- Download, verification, patching and registration from the GUI.
- Status pane row, confirmation dialog, and the "Install into Steam" fallback.

Out of scope: FEX, D3DMetal and DXMT, installing GStreamer, other Wine versions, updating
the pinned Wine, running a user-supplied Wine.

NotProton's README and CONTRIBUTING.md say non-CrossOver runtimes are not a project goal.
This feature is therefore intended for a fork unless the maintainer agrees to it.

## Findings from the feasibility spike

Static analysis with `ntdll-patch/resolve.py` only. Detours were not built and Steam was
not run.

- Bundle layout matches CrossOver below the root: `lib/wine/{x86_64-unix,x86_64-windows,i386-windows}`,
  `bin/wineserver`, `share/wine/wine.inf`. The root is
  `Wine Devel.app/Contents/Resources/wine` instead of `Contents/SharedSupport/CrossOver`.
- `i386-windows/ntdll.dll` resolves with the existing `resolve.py` unchanged.
- `x86_64-windows/ntdll.dll` does not resolve. Upstream builds `build_module` with an `rbp`
  frame (`lea rbp, [rsp+0x80]`, argument spilled to `[rbp-0x30]`). CrossOver's builds use
  `rsp`-relative slots, which `amd64_load_path` assumes. Checked by hand on 11.18, the hook
  site is correct and the slot is `rsp+0x50`, stable and not rewritten, so the existing
  shim should work once the resolver understands `rbp` frames.
- The 64-bit detour hardcodes `WINE_MODREF` offsets (`+0x30`, `+0x60`, `+0x68`). These are
  not yet verified against upstream 11.15 and must be checked during implementation.

## Pins (11.15 devel, from the spike)

| Item | SHA-256 |
|---|---|
| `wine-devel-11.15-osx64.tar.xz` (191,398,232 bytes) | `3f8e89a4874953a69e7be3dcdcc262d0346e462a9374bd116770fffb9e2a99d2` |
| `lib/wine/x86_64-unix/wine` (loader) | `8aa25e55f28a0634a7df04c02dd719d4bc20de645cf42b9ba7d0e3b7d8f66a80` |
| `lib/wine/x86_64-windows/ntdll.dll` (clean) | `682181234a55f5b7eed5b2ffa691fbdef1b488734337ef67ea7b5ce17adf43a2` |
| `lib/wine/i386-windows/ntdll.dll` (clean) | `49396e7ad804a5345b1b968d02fdb6697ddbb7428e61e20e62806c50c37589d1` |

The patched ntdll hashes are an output of the patching step and get pinned once the
payloads are built.

Download URL base: `https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.15/`

## Design

### 1. Runner model

`RunnerBuild` gains an `origin`: `.crossOver` (all existing entries) or `.downloadedWine`.
One new entry in `SupportedRunners.all`:

- `bundleVersion` / `releaseVersion`: `11.15`; `flavor`: `wine`, giving build id `11.15-wine`.
- Loader and ntdll pins from the table above; patched hashes added after patching.
- Tool: `notproton-wine-11.15`, flavor `.rosetta`, display "Wine 11.15 (free)". Added to
  `toolPreference` after the existing CrossOver names so CrossOver stays the default.

On disk the runtime lives at `runners/crossover-11.15-wine/CrossOver/`, with the contents of
`Wine Devel.app/Contents/Resources/wine` moved directly under `CrossOver/`. The name is
misleading, but the run script (`CX_ROOT`), the prefix-template regex, pruning, and the
Steam-side tool list all depend on that layout. Keeping it avoids touching all of those call
sites. A comment at `SupportPaths.clonedRoot` explains it. Renaming is follow-up work.

### 2. Downloader

New `Model/WineFetcher.swift`, modelled on `ValveFetcher`. Phases: downloading, extracting,
verifying, installing, finished.

1. `PinnedDownload.obtain(file:sha256:bases:into:step:from:)` with the tarball hash above.
   Cache in `~/Library/Caches/notproton/wine`. The `from:` source name is "GitHub".
2. Extract with `/usr/bin/tar -xf` into a fresh staging directory next to the target.
3. Verify the loader and both clean ntdll hashes against the pinned `RunnerBuild`, reusing
   `RunnerInstaller.verifyClone`.
4. Move the Wine root into `runners/crossover-11.15-wine/CrossOver` atomically, using the
   staging-then-rename approach in `RunnerInstaller.clone`.
5. Call `RunnerSetup.prepare`. The license check runs only for `.crossOver` builds.

Failures use `StepFailure`, as elsewhere. Quarantine attributes are scrubbed with
`RunnerInstaller.scrubDownloadMarkers`.

### 3. GUI

- **Status row.** In `crossOverSection`, a "Wine (free, open source)" row appears while
  the build is not set up. Button: **Download & Set Up**, prominent when no runner exists.
  When set up, the row behaves like other builds (size, Reinstall, Show in Finder, Remove
  Copy). The red "CrossOver: Not found" row is shown only when neither CrossOver nor the
  Wine build is available.
- **Confirmation.** Nothing is downloaded without a confirmation dialog stating: size
  (about 190 MB), source (Gcenx's macOS Wine builds on GitHub), license (LGPL), and
  limits (Rosetta only, no D3DMetal or DXMT, media codecs need GStreamer).
- **Install into Steam.** `installIntoSteam` shows the same dialog when there is no usable
  CrossOver and no runner, and on confirmation runs `WineFetcher` in place of
  `RunnerSetup.run(from:)`.
- All new user-facing strings are added to `Localizable.xcstrings`; `LocalizationTests`
  must pass.

### 4. Patching

- `ntdll-patch/resolve.py`: `amd64_load_path` learns `rbp` frames. It tracks
  `lea rbp, [rsp+K]` and converts `[rbp-N]` stores of the argument into an `rsp` offset
  `K-N`. The stability guard still applies. The existing self-test against CrossOver pins
  must keep passing unchanged.
- Build `detour2-wine1115.bin` and `detour32-wine1115.bin` via the existing build scripts.
  Add both clean hashes to `PAYLOAD_BY_CLEAN_SHA` in `apply.py`, add `PINNED` entries in
  `resolve.py`, add the build to `NtdllPatcher.byBuild`, and register the payloads in
  `payload.manifest` and the app resources.
- The `WINE_MODREF` offsets used by `detour.c` are checked against the 11.15 source tree.
  If they differ, the detour is parameterised per build.
- `compat_run.sh` is checked for CrossOver-only assumptions (`wineserver-x86`, D3DMetal
  and DXMT environment, the `crossover` user alias). The D3DMetal path and the
  `wineserver-x86` fallback are already guarded by file checks; the rest are audited and
  guarded where they are not.

### 5. Testing

Unit tests in the style of the existing ones:

- `SupportedRunners`: the new build resolves by loader hash and by id; tools and ordering.
- `CrossOverRow`/status states for the new origin.
- `WineFetcher` with a stubbed `URLSession` and a small fixture tarball: hash mismatch,
  unreachable host, extraction layout, atomic replacement of an existing install.
- License check is skipped for `.downloadedWine` and still enforced for `.crossOver`.

Real-world verification, run on this machine: download the real tarball, set up through
`RunnerSetup`, and confirm the patched ntdll hashes reproduce and `RunnerPatcher.verify`
passes. Launching a game needs a real Steam install and is left to the user. Success
there is `lsteamclient` loading and a Windows game starting.

## Risks

- The `lsteamclient` load has not been tried on this Wine. If the detour or `WINE_MODREF`
  assumptions fail at runtime, setup will succeed but games will not start.
- Gcenx may remove or replace the 11.15 release. The hash pin makes this fail loudly, and
  adding a mirror base URL is a one-line change.
- No D3DMetal or DXMT means MoltenVK and DXVK only, with worse performance and
  compatibility.
- Gcenx's builds expect GStreamer.framework for media. NotProton does not install it.

# DirectX 11 and Vulkan on the free Wine runtime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A user with the free Wine runtime can play DirectX 11 games and run Vulkan games without setting anything up. The app downloads a pinned DXVK, and the run script installs it into each game prefix at launch.

**Architecture:** A new `DXVKLayer` model (pinned archive and four DLL hashes, a `WineDownload` reused for the archive, a `run` that downloads, verifies and swaps the layer into the support directory). It runs as part of the free Wine setup and as a Status pane repair. The run script gets an `install_dxvk` step beside the existing per-prefix installs, gated on the stock-Wine check, which copies the DLLs by `cmp` and writes the `d3d11,d3d10core=n,b` override. CrossOver is not changed.

**Tech Stack:** Swift 6 / SwiftUI / Swift Testing (`make app-tests`, now runnable with Xcode 27.1), POSIX shell (`dylib/feats/compat_run.sh`, `dylib/tests/envcheck.sh`), `/usr/bin/tar`.

**Spec:** `docs/superpowers/specs/2026-10-18-dxvk-free-wine-design.md`

## Global Constraints

- Archive: `dxvk-macOS-async-v1.10.3-20230507-repack.tar.gz`, 2,793,443 bytes, SHA-256 `acd1520ad105d8ef124a09c8e11a259a5dc8bdc565ad18e0e52693f9807b2477`, from `https://github.com/Gcenx/DXVK-macOS/releases/download/v1.10.3-20230507-repack/`. Root directory in the archive: `dxvk-macOS-async-v1.10.3-20230507-repack`.
- The four DLLs and SHA-256s: `x64/d3d11.dll` `0ff0b0835dde29556bd01dfce7b1ae348d7f229cb1e1a37cc71ea1a028beeca4` (system32); `x64/d3d10core.dll` `0fa08bba860c63e3abeeabfc96d0e7aa327411a975f8f23d2dc63594ef5f796e` (system32); `x32/d3d11.dll` `f79d417f675d00008375eb4ea2318af6fcd0b27971d604d3cf345a0dcfa998a0` (syswow64); `x32/d3d10core.dll` `2277187a4e13fc2049fe28cb8dd05b34b48c68031c386c3597ba0e18b0c3d327` (syswow64). Ignore `dxvk.conf` and the `-builtin` archive.
- Installed layer: `~/Library/Application Support/notproton/dxvk/dxvk-macOS-async-v1.10.3-20230507-repack/{x64,x32}/`.
- Override written only for stock Wine (`np_stock_wine` set): `d3d11,d3d10core=n,b`. CrossOver runs must be byte-identical in environment and arguments.
- The run script compares files with `cmp` against the verified copy in the support directory. No hashes are duplicated in shell.
- DirectX 12 and DirectX 9 are not supported on this runtime. This is stated in the dialog, the README and the Status pane.
- New user-facing strings go in `Localizable.xcstrings` as English-only "new" entries, following the existing pattern.
- Comments are short, human, and only where the logic is hard.

## Review Focus

1. The launch step never runs for CrossOver (the `np_stock_wine` guard, with an envcheck case).
2. A failed copy never leaves a truncated DLL in a prefix (temporary name, then rename).
3. The archive is verified before anything leaves the cache, and extraction stays in its own directory.
4. The alert appears when the pinned layer is missing, and the launch continues without hanging.
5. The DirectX 12 and DirectX 9 limits appear in the dialog, the README and the Status pane.

## File Structure

| File | Responsibility |
|---|---|
| `app/Sources/NotProtonApp/Model/DXVKLayer.swift` (new) | Pinned descriptor, `installed`, `run` (download, verify, swap) |
| `app/Sources/NotProtonApp/Support/SupportPaths.swift` | `dxvk` and `dxvkDownloads` paths |
| `app/Sources/NotProtonApp/Model/WineFetcher.swift` | `nearestExisting` becomes internal, so `DXVKLayer` can reuse it |
| `app/Sources/NotProtonApp/SystemStatus.swift` | `dxvkInstalled` snapshot field, DXVK step in `downloadAndSetUp`, `repairDirectX()` |
| `app/Sources/NotProtonApp/Views/StatusView.swift` | Wine row detail and repair action, dialog copy |
| `app/Sources/NotProtonApp/Resources/Localization/Localizable.xcstrings` | New strings |
| `app/Tests/NotProtonAppTests/DXVKLayerTests.swift` (new) | Model tests, opt-in real download |
| `dylib/feats/compat_run.sh` | `install_dxvk`, its call in the prefix block, the override |
| `dylib/tests/envcheck.sh` | DXVK section of the run-script checks |
| `README.md` | Free Wine limits and the DirectX 11 layer |

---

### Task 1: The pinned layer and its paths

**Files:**
- Create: `app/Sources/NotProtonApp/Model/DXVKLayer.swift`
- Modify: `app/Sources/NotProtonApp/Support/SupportPaths.swift`
- Test: `app/Tests/NotProtonAppTests/DXVKLayerTests.swift`

**Interfaces:**
- Produces:
  - `struct DXVKFile: Sendable, Equatable { let archivePath: String; let prefixDirectory: String; let name: String; let sha256: String }`, with `prefixDirectory` `"system32"` or `"syswow64"`.
  - `struct DXVKLayer: Sendable, Equatable { let download: WineDownload; let files: [DXVKFile]; static let pinned: DXVKLayer; var directoryName: String { download.rootInArchive }; func directory(in root: URL) -> URL; func installed(in root: URL) -> Bool }`.
  - `SupportPaths.dxvk: URL` (`notproton/dxvk`) and `SupportPaths.dxvkDownloads: URL` (`~/Library/Caches/notproton/dxvk`).
- Consumes: `WineDownload` from `SupportedRunner.swift`, `Digest.sha256IfPresent`.

- [ ] **Step 1: Write the failing tests**

Tests in `DXVKLayerTests.swift`, Swift Testing, named as below.

- `pinnedLayerMatchesTheSpec`: `DXVKLayer.pinned.download.sha256` equals the archive hash; `download.file` is `dxvk-macOS-async-v1.10.3-20230507-repack.tar.gz`; `download.rootInArchive` is `dxvk-macOS-async-v1.10.3-20230507-repack`; `download.bases` is the release URL; `files` has exactly four entries whose `(archivePath, prefixDirectory, sha256)` triples equal the Global Constraints table.
- `installedNeedsEveryFileAndItsHash`: with an empty root, `installed` is false. After writing the four fixture files with the layer's own pins, it is true. After changing one byte of one file, it is false. (Use a `DXVKLayer` built from fixture bytes, so the test does not need the real DLLs.)
- `pathsAreUnderSupportAndCaches`: `SupportPaths.dxvk` ends in `notproton/dxvk`; `SupportPaths.dxvkDownloads` ends in `Library/Caches/notproton/dxvk`.

- [ ] **Step 2: Run to verify failure**

Run: `cd app && swift test --no-parallel --filter DXVKLayer`
Expected: compile error, `DXVKLayer` not found.

- [ ] **Step 3: Implement**

Write `DXVKLayer.swift` with the types above. `installed(in:)` checks each file's hash with `Digest.sha256IfPresent`. The pinned values come from the Global Constraints. `directory(in:)` returns `root.appending(path: directoryName)`.

- [ ] **Step 4: Run to verify it passes**

Run: `cd app && swift test --no-parallel --filter DXVKLayer`
Expected: all three pass.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/NotProtonApp/Model/DXVKLayer.swift app/Sources/NotProtonApp/Support/SupportPaths.swift app/Tests/NotProtonAppTests/DXVKLayerTests.swift
git commit -m "Add the pinned DXVK layer model"
```

### Task 2: Download, verify and install the layer

**Files:**
- Modify: `app/Sources/NotProtonApp/Model/DXVKLayer.swift`, `app/Sources/NotProtonApp/Model/WineFetcher.swift` (make `nearestExisting` internal)
- Test: `app/Tests/NotProtonAppTests/DXVKLayerTests.swift`

**Interfaces:**
- Produces: `func run(downloads: URL = SupportPaths.dxvkDownloads, root: URL = SupportPaths.dxvk, session: URLSession = PinnedDownload.session, availableBytes: (URL) -> Int64? = WineFetcher.availableBytes(at:), report: @Sendable (String) -> Void = { _ in }) async throws`, on `DXVKLayer`. Throws `StepFailure` with step `String(localized: "Download DirectX layer")`.
- Consumes: `PinnedDownload.obtain(file:sha256:bases:into:step:from:session:report:)`, `RunnerInstaller.swapIn(staging:target:)`, `WineFetcher.nearestExisting`.

- [ ] **Step 1: Write the failing tests**

Each test builds a fixture layer (a real `.tar.gz` made at test time with `/usr/bin/tar -czf`, with root `fixture-dxvk` and the four fixture DLLs) and serves it from a `file://` base, as `WineFetcherTests` does.

- `installsAGoodArchive`: after `run`, `installed(in:)` is true, and no `.new` or `.extract` directory is left under the root.
- `tamperedArchiveInstallsNothing`: the served archive does not match the pin, so `run` throws, and the root and downloads directory contain no archive.
- `wrongDLLInsideTheArchiveInstallsNothing`: the archive hash matches, but one DLL's pin is wrong. `run` throws and nothing is installed.
- `alreadyInstalledIsNoOp`: after one run, a second run with a base that has no file succeeds, which proves no network access.
- `lowDiskIsRefusedBeforeDownload`: `availableBytes` returns less than `requiredFreeBytes`; `run` throws and the downloads directory is never created.
- `realArchiveDownloads` (opt-in: `NOTPROTON_TEST_WINE_DOWNLOAD=1`): runs `DXVKLayer.pinned.run` into scratch directories and expects `installed(in:)` true.

- [ ] **Step 2: Run to verify failure**

Run: `cd app && swift test --no-parallel --filter DXVKLayer`
Expected: `run` not found.

- [ ] **Step 3: Implement**

`run` order: return early if `installed(in: root)`; free-space check against `requiredFreeBytes` using `nearestExisting(root)`; `PinnedDownload.obtain` with the archive pin; extract with `/usr/bin/tar -xf archive -C staging` inside a fresh `root/.dxvk-extract` directory; verify the four files under `extract/<directoryName>/<archivePath>`; `RunnerInstaller.swapIn(staging: extract/<directoryName>, target: directory(in: root))`; remove the extraction directory in a `defer`. Report progress with the strings "Downloading DirectX layer" and "Installing DirectX layer".

- [ ] **Step 4: Run to verify it passes**

Run: `cd app && swift test --no-parallel --filter DXVKLayer`
Expected: all pass. The opt-in test is skipped unless the variable is set.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/NotProtonApp/Model app/Tests/NotProtonAppTests/DXVKLayerTests.swift
git commit -m "Download, verify and install the DXVK layer"
```

### Task 3: Setup, status, and the Wine row

**Files:**
- Modify: `app/Sources/NotProtonApp/SystemStatus.swift`, `app/Sources/NotProtonApp/Views/StatusView.swift`, `app/Sources/NotProtonApp/Resources/Localization/Localizable.xcstrings`
- Test: `app/Tests/NotProtonAppTests/DXVKLayerTests.swift` (copy rules), existing `SystemStatusTests.swift` and `CrossOverRowTests.swift` must still pass

**Interfaces:**
- Consumes: `DXVKLayer.pinned.run`, `DXVKLayer.pinned.installed(in:)`.
- Produces:
  - `StatusSnapshot.dxvkInstalled: Bool`, set in `capture`.
  - `SystemStatus.repairDirectX() async`: guard `canInstall`; `perform` with the installation lock and `requireInstallableContent`; runs the layer; returns "DirectX 11 layer ready."
  - `downloadAndSetUp` runs the layer after `RunnerSetup.run(downloading:)` returns, so a Wine setup always brings the layer with it.
  - Wine row: `crossOverDetail` adds "DirectX 11 layer not installed." when `row.isDownloadable && row.copy == .ready && !snapshot.dxvkInstalled`; `crossOverAction` adds `case .ready where row.isDownloadable && !dxvkInstalled` returning a prominent "Repair" that calls `repairDirectX()`.
  - `Self.wineAbout` gains: "DirectX 11 games also use DXVK, about 3 MB, free under zlib. DirectX 12 and DirectX 9 games are not supported on this runtime."

- [ ] **Step 1: Write the failing tests**

- In `DXVKLayerTests.swift`, `dxvkDetailAppearsOnlyForAMissingLayer`: a pure helper `StatusView.directXNeedsRepair(isDownloadable:copy:installed:) -> Bool` returns true only for a downloadable `.ready` row without the layer. Put the helper beside `notFoundTone` so it is testable.
- No unit test for the order of setup steps (Wine, then the layer). That order lives inside `downloadAndSetUp`, which needs the real installer. The implementer states in the report that it was checked by reading the code, and Task 5 Step 4 checks the Status pane action on a real build.

- [ ] **Step 2: Run to verify failure**

Run: `cd app && swift test --no-parallel --filter DXVKLayer`
Expected: `directXNeedsRepair` not found.

- [ ] **Step 3: Implement**

Add the snapshot field and its capture. Add the DXVK step to `downloadAndSetUp`, after the Wine setup. Add `repairDirectX()`. Add the detail and action in `StatusView` using the helper. Update `wineAbout`. Add the English catalog entries for every new literal: "DirectX 11 layer not installed.", "Repair", the repair help, "DirectX 11 layer ready.", "Downloading DirectX layer", "Installing DirectX layer", "Download DirectX layer", and the new `wineAbout` text. Validate the catalog with `python3 -I -c 'import json; json.load(open(...))'`.

- [ ] **Step 4: Run to verify it passes**

Run: `cd app && swift test --no-parallel --filter "DXVKLayer|SystemStatus|CrossOverRow|LocalizationTests"`
Expected: pass. Then `make app-tests` for the full suite; expected 570 tests with 0 issues, plus the new ones.

- [ ] **Step 5: Commit**

```bash
git add app
git commit -m "Install the DXVK layer with the free Wine and offer its repair"
```

### Task 4: The run script's DXVK step

**Files:**
- Modify: `dylib/feats/compat_run.sh` (new `install_dxvk` after `install_lsteamclient_trigger` at about line 1147; called inside the prefix block next to line 1284; override prepended to `WINEDLLOVERRIDES` where `vc_overrides` is built)
- Test: `dylib/tests/envcheck.sh` (new section "DirectX 11 layer")

**Interfaces:**
- Produces: `install_dxvk` sets `np_dxvk_overrides` (empty, or `d3d11,d3d10core=n,b;`) and returns 0. On a missing layer it calls `show_alert` and returns 0, so the launch continues. A failed copy returns 1, and the caller's existing failure path applies.
- Consumes: `$np_support`, `$WINEPREFIX`, `$log`, `$np_stock_wine`, `show_alert`.

- [ ] **Step 1: Write the failing tests**

In `envcheck.sh`, using a temporary tree and the sed-extracted function (the pattern of the Wine user section):

- `stockPrefixGetsTheLayerAndTheOverride`: prefix with `system32` and `syswow64`, layer present, `np_stock_wine=1`. Afterwards the four files are `cmp`-equal to the layer, and `np_dxvk_overrides` is `d3d11,d3d10core=n,b;`.
- `crossOverRunsAreUntouched`: `np_stock_wine` empty. Nothing is copied and `np_dxvk_overrides` is empty.
- `missingLayerAlertsAndContinues`: no layer directory. The recorded alert fires once, `np_dxvk_overrides` is empty, and the function returns 0.
- `noSysWow64SkipsTheSecondArchitecture`: no `syswow64` directory. The x64 files are copied, the x32 step is skipped, and the override is still set.
- `unchangedFilesAreNotRewritten`: a second call leaves the file's inode unchanged (compare with `ls -i` or `stat -f %i`).

Each assertion is a line in the existing `is` style.

- [ ] **Step 2: Run to verify failure**

Run: `make envcheck`
Expected: FAIL, "the DXVK blocks were not found".

- [ ] **Step 3: Implement**

`install_dxvk` (POSIX sh, `#!/bin/sh` compatible):

```sh
install_dxvk() {
  np_dxvk_overrides=""
  [ -n "$np_stock_wine" ] || return 0
  dxvk_root="$np_support/dxvk/dxvk-macOS-async-v1.10.3-20230507-repack"
  if [ ! -f "$dxvk_root/x64/d3d11.dll" ]; then
    show_alert "DirectX 11 layer is missing" "NotProton could not find DXVK for this game. Open NotProton's Status pane and repair the Wine row."
    return 0
  fi
  # ... per file: cmp -s, copy to "$dst.notproton-tmp", mv over "$dst"
  np_dxvk_overrides="d3d11,d3d10core=n,b;"
}
```

For x64 files go to `$WINEPREFIX/drive_c/windows/system32`. For x32 files go to `$WINEPREFIX/drive_c/windows/syswow64`, and skip them if that directory does not exist. A failed copy returns 1 with a log line. Then in the prefix block, after `install_lsteamclient_trigger`, call `install_dxvk`, and prepend `$np_dxvk_overrides` to `vc_overrides` before `WINEDLLOVERRIDES` is exported.

- [ ] **Step 4: Run to verify it passes**

Run: `make envcheck && make scriptcheck runcheck`
Expected: every new assertion passes, the old ones are unchanged, and shellcheck 0.11.0 reports nothing new. If shellcheck flags the temporary-file pattern, add a justified disable comment, as in the earlier envcheck fix.

- [ ] **Step 5: Commit**

```bash
git add dylib/feats/compat_run.sh dylib/tests/envcheck.sh
git commit -m "Install the DXVK layer into stock Wine prefixes at launch"
```

### Task 5: Real verification

**Files:** none changed unless a check fails.

- [ ] **Step 1: Real archive**

Run: `NOTPROTON_TEST_WINE_DOWNLOAD=1 make app-tests` (or `swift test --no-parallel --filter realArchiveDownloads`).
Expected: the real 2.8 MB archive downloads, verifies, and installs.

- [ ] **Step 2: Vulkan through the run script's environment**

Build `vkprobe.exe` (the probe in the scratchpad) and run it with the environment a real launch logs: `WINEPREFIX`, `WINEDLLPATH` and `WINEDLLOVERRIDES` from `notproton-run.log`, under the runner's `wine` binary. Expected: `device 0: Apple M4 ... vulkan 1.2`.

- [ ] **Step 3: DirectX 11 in a scratch prefix**

Copy the layer into a scratch prefix with the same logic as `install_dxvk`, set `WINEDLLOVERRIDES="d3d11,d3d10core=n,b"`, and run the D3D11 feature-level probe. Expected: feature level 0xb000 (11_0) and a device.

- [ ] **Step 4: Full checks**

Run: `make app && make app-tests && make scriptcheck runcheck envcheck`
Expected: the app builds, all Swift tests pass, and the script checks pass. Record the counts.

- [ ] **Step 5: Commit any fixes**

Commit only what a failing check required, with a message that names it.

### Task 6: README and handover

**Files:**
- Modify: `README.md` (the Free Wine section)

- [ ] **Step 1: Update the limits**

State that DirectX 11 works through DXVK, which NotProton downloads and installs automatically; that Vulkan works; that DirectX 12 and DirectX 9 are not supported on this runtime; and that CrossOver remains the best-supported option. Keep the wording short. Remove any line that implies DirectX 12 or DirectX 9 games run.

- [ ] **Step 2: Verify the claims**

Check every statement against the test results from Task 5. Note in the commit message which parts were verified by probe and which by real launch (the real launch is the user's test).

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "Document the DirectX 11 layer and the free Wine limits"
```

## Self-Review

Spec coverage: pin and download (Tasks 1–2), launch install and override (Task 4), setup and status (Task 3), Vulkan verification (Task 5), out-of-scope limits (Tasks 3 and 6), and testing (all tasks).

Type consistency: `DXVKLayer`, `DXVKFile`, `run(downloads:root:session:availableBytes:report:)`, `installed(in:)`, `repairDirectX()`, `dxvkInstalled` and `np_dxvk_overrides` are used with the same names in every task.

Open point for review: the spec says a missing layer shows an alert on every launch until it is repaired. That includes Vulkan-only games, which do not need DXVK. The plan follows the spec. If that is too noisy, say so and I will change the rule to alert only for games that use Direct3D 11.

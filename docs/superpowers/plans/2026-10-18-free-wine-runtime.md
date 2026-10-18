# Free Wine Runtime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A user without CrossOver can click one button in the Status pane to download, verify, patch and register Gcenx `wine-devel` 11.15 as a Steam compatibility tool.

**Architecture:** `RunnerBuild` gains an `origin` (`.crossOver` or `.downloadedWine(WineDownload)`). A new `WineFetcher` downloads the pinned tarball with `PinnedDownload`, extracts it, verifies it with `RunnerInstaller.verifyClone`, and swaps it into `runners/crossover-11.15-wine/CrossOver/`. The existing `RunnerSetup.prepare` then patches and registers it with the license check skipped. The ntdll detour payloads for the new build come from `ntdll-patch/` after `resolve.py` learns `rbp`-framed `build_module`.

**Tech Stack:** Swift 6 / SwiftUI / Swift Testing (`swift test --no-parallel` in `app/`), Python 3 + capstone (`ntdll-patch/`), mingw-w64 cross compilers, shell.

**Spec:** `docs/superpowers/specs/2026-10-18-free-wine-runtime-design.md`

## Global Constraints

- Branch `free-wine-runtime`; one commit per task; never touch `main`.
- Pinned runtime: Gcenx `wine-devel` 11.15, `wine-devel-11.15-osx64.tar.xz`, 191,398,232 bytes, SHA-256 `3f8e89a4874953a69e7be3dcdcc262d0346e462a9374bd116770fffb9e2a99d2`.
- Download base: `https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.15/`. Archive root: `Wine Devel.app/Contents/Resources/wine`.
- Loader `lib/wine/x86_64-unix/wine` SHA-256 `8aa25e55f28a0634a7df04c02dd719d4bc20de645cf42b9ba7d0e3b7d8f66a80`.
- Clean ntdll: x86_64 `682181234a55f5b7eed5b2ffa691fbdef1b488734337ef67ea7b5ce17adf43a2`; i386 `49396e7ad804a5345b1b968d02fdb6697ddbb7428e61e20e62806c50c37589d1`. No aarch64.
- Build id `11.15-wine` (bundleVersion `11.15`, releaseVersion `11.15`, flavor `wine`). On-disk root `runners/crossover-11.15-wine/CrossOver/` (name kept deliberately; see spec section 1).
- Tool `notproton-wine-11.15`, flavor `.rosetta`, display `Wine 11.15 (free)`; ranked after every existing CrossOver tool in `SupportedRunners.toolPreference`.
- Rosetta only: no FEX, no D3DMetal/DXMT, no GStreamer install, no other Wine versions, no bring-your-own-Wine.
- CrossOver behaviour, hashes and tool names must not change. Every existing test keeps passing.
- Comments: short, human, only where the logic is hard. New user-facing strings go in `Localizable.xcstrings`.
- The shipped `lsteamclient`/`steam-shim` bridge binaries target Wine 11.15 and are reused unchanged.

## Review Focus

Failure modes the spec implies; each has a pinning test in the task that owns the code.

1. Download interrupted, tampered with, or the GitHub release removed: nothing partial is left, no `.new` staging directory, no half-installed runner (Task 4).
2. Second click when already set up: no network, no re-extract (Task 4).
3. Not enough free disk space for download plus extraction: refused before any download (Task 4).
4. A game or Wine tool is running on the build being replaced: refused (Task 4).
5. Archive paths contain a space (`Wine Devel.app`): extraction and move must cope (Task 4, fixture uses the real name).

## File Structure

| File | Responsibility |
|---|---|
| `ntdll-patch/resolve.py` | Resolver learns `rbp` frames; `PINNED` entries for the two new clean ntdlls |
| `ntdll-patch/apply.py`, `build-ntdll.sh` | Register the new payloads / flavor `wine1115` |
| `app/Sources/NotProtonApp/Resources/detour{2,32}-wine1115.bin` | Built payloads |
| `app/Package.swift` | Copy the two payloads as resources |
| `Model/SupportedRunner.swift` | `RunnerOrigin`, `WineDownload`, new build entry, tool ranking, `title` |
| `Model/NtdllPatcher.swift` | `byBuild["11.15-wine"]` patch table |
| `Model/WineFetcher.swift` (new) | Download, extract, verify, swap in |
| `Model/RunnerInstaller.swift` | Share the staging swap between `clone` and the fetcher |
| `Model/RunnerSetup.swift` | Skip license for wine origin; `run(downloading:)` composition |
| `Model/CrossOverRow.swift` | Downloadable rows and titles |
| `Support/SupportPaths.swift` | `wineDownloads` cache path |
| `SystemStatus.swift`, `Views/StatusView.swift` | Confirmation, actions, rows, install-flow fallback |
| `Resources/Localization/Localizable.xcstrings` | New strings |
| `README.md`, `CONTRIBUTING.md` | Document the free option for this fork |

---

### Task 1: Resolver understands `rbp` frames

**Files:**
- Modify: `ntdll-patch/resolve.py` (`amd64_load_path`, around line 341)

**Interfaces:**
- Produces: `resolve.py <x86_64 ntdll.dll>` exits 0 for upstream Wine 11.15 and reports `load_path` as an `rsp+0xNN` slot. CrossOver self-tests are unchanged.

Scratch inputs: download `wine-devel-11.15-osx64.tar.xz` into a new empty directory under the scratchpad, extract it, and use `Wine Devel.app/Contents/Resources/wine/lib/wine/x86_64-windows/ntdll.dll`. Use a venv with `capstone` and run Python with `-I`.

- [ ] **Step 1: Capture the failing baseline**

Run: `python -I ntdll-patch/resolve.py <11.15 x86_64 ntdll.dll>`
Expected: exit 1, `load_path slot rewritten at 0x34fc3`.

- [ ] **Step 2: Capture the CrossOver baseline**

Run `resolve.py` on every x86_64 and i386 `ntdll.dll` of the CrossOver in `/Applications` whose sha256 appears in `PINNED`. Save the output. Expected: `self-test: all pinned values reproduced`. If no installed CrossOver matches a pin, say so and rely on step 4's synthetic check.

- [ ] **Step 3: Extend `amd64_load_path(pe, body, hook)`**

When the argument is spilled to `qword ptr [rbp - N]` and an earlier `lea rbp, [rsp + K]` exists in the same function, return slot `K - N`. Keep the existing `rsp`-direct and register-stash paths and the stability guard. The guard must also reject any `sub/add rsp`, `push`, `pop` or `lea rbp` between the `lea rbp` and the hook, and any later store to `[rbp - N]` or `[rsp + slot]`.

- [ ] **Step 4: Verify both baselines**

Run the 11.15 command: expected exit 0 and output with `load_path rsp+0x..`, a `wm` register, `hookRVA`, `stolen`, `resume`, and exports. Re-run step 2's commands: output identical to the baseline. Record the 11.15 values (`hookRVA`, `stolen`, `wm`, `load_path`, `caveRVA`, `caveSize`, `placement`, `exports`) in the task notes; Task 2 pins them.

- [ ] **Step 5: Commit**

```bash
git add ntdll-patch/resolve.py
git commit -m "Teach resolve.py about rbp-framed build_module"
```

### Task 2: Build and pin the detour payloads

**Files:**
- Modify: `ntdll-patch/resolve.py` (`PINNED`, `PAYLOAD` unchanged), `ntdll-patch/apply.py` (`PAYLOAD_BY_CLEAN_SHA`), `ntdll-patch/build-ntdll.sh`, `app/Package.swift`
- Create: `app/Sources/NotProtonApp/Resources/detour2-wine1115.bin`, `detour32-wine1115.bin`

**Interfaces:**
- Consumes: the Task 1 resolver and its recorded 11.15 values.
- Produces: the two `.bin` files, their SHA-256s, and the SHA-256 of the patched x86_64 and i386 ntdll. Task 3 reads these.

- [ ] **Step 1: Install the toolchain**

Run: `brew install mingw-w64`. Verify `x86_64-w64-mingw32-gcc --version` and `i686-w64-mingw32-gcc --version` print versions. If `brew` is unavailable, stop and report.

- [ ] **Step 2: Check the `WINE_MODREF` assumption**

`detour.c` hardcodes `dllbase +0x30`, name `+0x60`, flags `+0x68`. Fetch Wine 11.15 `dlls/ntdll/loader.c` (git tag `wine-11.15`, commit `2df1ee28039cf84776eb1421ed90bd154cebb65f`) and confirm the `WINE_MODREF` layout gives those offsets for x86_64. If they differ, parameterise `detour.c` with a macro set by `build.sh` and keep CrossOver payload hashes unchanged (rebuild a CrossOver payload and compare its hash). Write what you found in the commit message.

- [ ] **Step 3: Register the build**

In `resolve.py` add `PINNED` entries for both clean hashes from Global Constraints, filled from the Task 1 values and the payload hashes from step 4 (add them after the first build, then rebuild to confirm). In `apply.py` map each clean hash to `detour2-wine1115.bin` / `detour32-wine1115.bin`. In `build-ntdll.sh` add flavor `wine1115` modelled on `rosetta-41073` in every `case` (pins, `BUILD=11.15-wine`, tools list, `patch_one` calls with variant `wine1115`) and `CX_ROOT` pointing at the extracted wine root.

- [ ] **Step 4: Build and verify**

Run `ntdll-patch/build-ntdll.sh` with `FLAVOR=wine1115` against the extracted 11.15 tree. Expected: both payloads built, patched `ntdll.dll` files produced, no pin errors. Record the payload SHA-256s and the patched ntdll SHA-256s. Re-run to confirm the same hashes (reproducible).

- [ ] **Step 5: Ship the payloads**

Copy both `.bin` files into `app/Sources/NotProtonApp/Resources/`. Add `.copy("Resources/detour2-wine1115.bin")` and `.copy("Resources/detour32-wine1115.bin")` to `app/Package.swift` beside the others.

- [ ] **Step 6: Commit**

```bash
git add ntdll-patch app/Package.swift app/Sources/NotProtonApp/Resources/detour2-wine1115.bin app/Sources/NotProtonApp/Resources/detour32-wine1115.bin
git commit -m "Build the ntdll detours for Wine 11.15"
```

### Task 3: The build entry, origin and patch table

**Files:**
- Modify: `Model/SupportedRunner.swift`, `Model/NtdllPatcher.swift` (`byBuild`)
- Test: `app/Tests/NotProtonAppTests/DetectionTests.swift` (new suite `Downloaded Wine build`)

**Interfaces:**
- Produces:
  - `struct WineDownload: Sendable, Equatable { let file: String; let sha256: String; let bases: [URL]; let rootInArchive: String; let approximateBytes: Int64; let requiredFreeBytes: Int64 }`
  - `enum RunnerOrigin: Sendable, Equatable { case crossOver; case downloadedWine(WineDownload) }`
  - On `RunnerBuild`: `var origin: RunnerOrigin = .crossOver`, `var download: WineDownload?`, `var isDownloadedWine: Bool`, `var title: String` (CrossOver: `"CrossOver \(displayVersion)"`; wine: `"Wine \(releaseVersion) (free)"`). `matching(loaderSHA256:)` must carry `origin` through.
  - `SupportedRunners.downloadable: [RunnerBuild]` (all builds with `isDownloadedWine`).
- Values: `approximateBytes` 191_398_232; `requiredFreeBytes` 1_200_000_000 (download plus about 720 MB extracted, plus margin).

- [ ] **Step 1: Write the failing tests**

```swift
@Test("The free Wine build is pinned and tooled as specified")
func wineBuildPinned() throws {
    let build = try #require(SupportedRunners.build(id: "11.15-wine"))
    #expect(build.isDownloadedWine)
    #expect(build.loaderSHA256 == "8aa25e55f28a0634a7df04c02dd719d4bc20de645cf42b9ba7d0e3b7d8f66a80")
    #expect(build.cleanNtdll[.x86_64Windows] == "682181234a55f5b7eed5b2ffa691fbdef1b488734337ef67ea7b5ce17adf43a2")
    #expect(build.cleanNtdll[.i386Windows] == "49396e7ad804a5345b1b968d02fdb6697ddbb7428e61e20e62806c50c37589d1")
    #expect(build.cleanNtdll[.aarch64Windows] == nil)
    #expect(build.tools.map(\.name) == ["notproton-wine-11.15"])
    #expect(build.tools.first?.flavor == .rosetta)
    #expect(build.download?.sha256 == "3f8e89a4874953a69e7be3dcdcc262d0346e462a9374bd116770fffb9e2a99d2")
    #expect(build.title == "Wine 11.15 (free)")
}

@Test("A CrossOver build is never downloadable and a rebuild keeps its origin")
func originSurvives() { /* every non-wine build: origin == .crossOver, download == nil;
   SupportedRunners.build(loaderSHA256: wine loader) keeps origin; downloadable == [wine build] */ }

@Test("The free Wine tool ranks after every CrossOver tool")
func wineRanksLast() { /* tools(for: all builds, fexAvailable: true).last?.name == "notproton-wine-11.15";
   the order of the other names is unchanged from before this change */ }
```

- [ ] **Step 2: Run to verify failure**

Run: `cd app && swift test --no-parallel --filter DetectionTests`
Expected: FAIL, `isDownloadedWine`/build `11.15-wine` not found.

- [ ] **Step 3: Implement**

Add the types, the `RunnerBuild` members, and the `SupportedRunners.all` entry (loader, clean and patched ntdll from Global Constraints and Task 2, `flavor: "wine"`). Append `"notproton-wine-11.15"` to `toolPreference`. `flavorName` for a wine origin is `"Wine"`. Add `NtdllPatch` entries for `.x86_64Windows` and `.i386Windows` under `"11.15-wine"` in `NtdllPatcher.byBuild`, from the Task 1/2 values (`payloadResource` `detour2-wine1115` / `detour32-wine1115`, payload hashes from Task 2, `caveRVA`, `payloadRVA`, `hooks`, `caveSize`, `cavePad`, `machine`, `magic`, `imageBase`, `placement`).

- [ ] **Step 4: Run the whole suite**

Run: `cd app && swift test --no-parallel`
Expected: all pass, including the existing invariants over `SupportedRunners.all` (`rowsAreComplete`, `shippedPayloadsMatch`, `patchesMatchRecordedArches`).

- [ ] **Step 5: Prove the patch reproduces the pinned hash**

Add an opt-in test `patchedNtdllReproduces` (skipped unless `NP_WINE_ROOT` names an extracted Wine root) that runs `NtdllPatcher.write(patch, build:, from: cleanSource, to:)` for both arches and expects `Digest.sha256(of: output) == build.patchedNtdll[arch]`. Run it with `NP_WINE_ROOT` set to the Task 1 extraction. Expected: PASS for both arches.

- [ ] **Step 6: Commit**

```bash
git add app
git commit -m "Add the free Wine 11.15 build and its ntdll patches"
```

### Task 4: `WineFetcher`

**Files:**
- Create: `app/Sources/NotProtonApp/Model/WineFetcher.swift`, `app/Tests/NotProtonAppTests/WineFetcherTests.swift`
- Modify: `Model/RunnerInstaller.swift`, `Support/SupportPaths.swift`

**Interfaces:**
- Consumes: `RunnerBuild.download`, `PinnedDownload.obtain`, `RunnerInstaller.verifyClone(build:root:)`, `RunnerInstaller.hasClone`, `RunnerInstaller.scrubDownloadMarkers`, `RunnerInstaller.isRunning`.
- Produces:
  - `SupportPaths.wineDownloads: URL` = `~/Library/Caches/notproton/wine`.
  - `RunnerInstaller.swapIn(staging: URL, target: URL) throws`: removes `target` if present, then moves `staging` to it. `clone` is changed to use it, behaviour unchanged.
  - `WineFetcher.Phase` (`downloading(PinnedDownload.Progress)`, `extracting`, `verifying`, `installing`, `finished`) with `var label: String`.
  - `WineFetcher.run(_ build: RunnerBuild, replacingExisting: Bool = false, runners: URL = SupportPaths.runners, downloads: URL = SupportPaths.wineDownloads, session: URLSession = PinnedDownload.session, availableBytes: (URL) -> Int64? = WineFetcher.availableBytes(at:), running: (URL) -> Bool = { RunnerInstaller.isRunning(from: $0) }, report: @Sendable (Phase) -> Void = { _ in }) async throws -> RunnerBuild` (`async throws`, throws `StepFailure`).

Tests build a tiny `.tar.xz` at runtime with `/usr/bin/tar -cJf`, containing `Wine Devel.app/Contents/Resources/wine/lib/wine/x86_64-unix/wine` and the two `ntdll.dll` files, then construct a `RunnerBuild` whose pins are the fixture's own hashes and whose `WineDownload.bases` is a `file://` directory (see `PinnedDownloadTests`).

- [ ] **Step 1: Write the failing tests**

```swift
@Test("A good archive is installed under crossover-<id>/CrossOver and passes verification")
func installs() async throws { /* returns build; clonedRoot has lib/wine/x86_64-unix/wine;
   no ".crossover-*.new" left in runners; RunnerInstaller.hasClone == true */ }

@Test("A tampered archive installs nothing")
func tamperedLeavesNothing() async throws { /* serve different bytes; throws StepFailure;
   runners is empty (no target, no staging); downloads has no archive */ }

@Test("An archive whose loader is not the pinned one installs nothing")
func wrongLoaderLeavesNothing() async throws { /* valid archive hash, loader hash differs from build pin */ }

@Test("An unreachable host fails without touching runners")
func unreachable() async throws { /* base dir without the file */ }

@Test("Already set up is a no-op that never touches the network")
func reuse() async throws { /* install once; second run with a base that has no file succeeds;
   replacingExisting: false */ }

@Test("replacingExisting swaps the clone")
func replaces() async throws { /* pre-existing clone with a marker file; after run the marker is gone */ }

@Test("Too little free space is refused before any download")
func lowDisk() async throws { /* availableBytes returns requiredFreeBytes - 1; throws StepFailure;
   downloads dir not created */ }

@Test("A running game on the build refuses a replace")
func runningRefused() async throws { /* running returns true, replacingExisting: true; throws; existing clone untouched */ }
```

- [ ] **Step 2: Run to verify failure**

Run: `cd app && swift test --no-parallel --filter WineFetcherTests`
Expected: compile FAIL, `WineFetcher` not defined.

- [ ] **Step 3: Implement**

- `RunnerInstaller.swapIn` extracted from the tail of `clone`; `clone` calls it.
- `WineFetcher.run` order: reuse short-circuit (clone exists and not replacing: `verifyClone`, return) → free-space check on the nearest existing ancestor of `runners` → refuse if `running` for a replace → `PinnedDownload.obtain(file:sha256:bases:into:step:from: "GitHub", report:)` → extract with `Shell.run("/usr/bin/tar", ["-xf", archive, "-C", extractDir])` into a fresh directory inside `runners` → move `extractDir/<rootInArchive>` to `<staging>/CrossOver` → `scrubDownloadMarkers` → `verifyClone(build:root:)` → `swapIn`. Clean up staging and extract directories on every exit path (`defer`). Step name for failures: `String(localized: "Download Wine")`.
- `availableBytes(at:)` reads `.volumeAvailableCapacityForImportantUsageKey`.

- [ ] **Step 4: Run to verify they pass**

Run: `cd app && swift test --no-parallel --filter WineFetcherTests` then the full suite.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app
git commit -m "Add WineFetcher to download and install the free Wine"
```

### Task 5: Setup composition, license skip and row model

**Files:**
- Modify: `Model/RunnerSetup.swift`, `Model/CrossOverRow.swift`
- Test: `RunnerSetupTests.swift`, `CrossOverRowTests.swift`

**Interfaces:**
- Consumes: `WineFetcher.run`, `RunnerBuild.origin/title/isDownloadedWine`.
- Produces:
  - `RunnerSetup.run(downloading build: RunnerBuild, replacingExisting: Bool = false, report: @Sendable (String) -> Void = { _ in }) async throws -> Outcome` (labels from `WineFetcher.Phase.label` then `RunnerSetup.Phase.label`).
  - `RunnerSetup.prepare` skips the `license` closure when `build.origin` is not `.crossOver`.
  - `CrossOverRow.isDownloadable: Bool`; `title` uses `build?.title` when there is no install; `rows(..., downloadable: [RunnerBuild] = [])` appends a `.none` row (no install) for each downloadable build not already present.

- [ ] **Step 1: Write the failing tests**

```swift
@Test("prepare never calls the license check for a downloaded Wine")
func wineSkipsLicense() throws { /* stub license closure records a call and returns unlicensed;
   prepare(wineBuild, ...) succeeds with all other closures stubbed; call count == 0 */ }

@Test("prepare still enforces the license for CrossOver")
func crossOverStillLicensed() throws { /* unlicensed closure → StepFailure; unchanged behaviour */ }

@Test("A downloadable build with no copy gets a row that can be downloaded")
func downloadableRow() { /* rows(..., downloadable: [wine]) contains buildID "11.15-wine", copy .none,
   isDownloadable, install == nil, canSetUp == false, title == "Wine 11.15 (free)";
   with the default argument the existing rows are unchanged */ }

@Test("An installed wine copy does not get a second row")
func noDuplicateRow() { /* installed: [wine], downloadable: [wine] → exactly one row, copy .ready */ }
```

- [ ] **Step 2: Run to verify failure**

Run: `cd app && swift test --no-parallel --filter "RunnerSetup|CrossOverRow"`
Expected: FAIL, new API missing.

- [ ] **Step 3: Implement**, then run the full suite.

- [ ] **Step 4: Commit**

```bash
git add app
git commit -m "Set up a downloaded Wine without a license check"
```

### Task 6: Status model and confirmations

**Files:**
- Modify: `SystemStatus.swift`
- Test: `SystemStatusTests.swift`

**Interfaces:**
- Consumes: `RunnerSetup.run(downloading:replacingExisting:report:)`, `SupportedRunners.downloadable`.
- Produces:
  - `Confirmation` gains `.downloadWine` and `.installWithWine`.
  - `nonisolated static func wineOffer(hasUsableCrossOver: Bool, runner: RunnerState) -> Bool` (true only when there is no usable CrossOver and `runner == .none`).
  - `func requestWineDownload(replacingExisting: Bool = false)` (sets `pendingConfirmation = .downloadWine`, remembers the flag) and `func downloadWine() async` (runs under `perform`, takes the installation lock, calls `requireInstallableContent`, then `RunnerSetup.run(downloading:)`, result text via `runnerOutcome`).
  - `requestInstall()` sets `.installWithWine` when `wineOffer` is true; `installIntoSteam(downloadingWine: Bool = false)` downloads when the flag is set and no runner exists after the Steam install; `crossOverRows` passes `SupportedRunners.downloadable`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test("Wine is offered only with no usable CrossOver and no runner")
func wineOfferTruthTable() { /* (false, .none) → true; (true, .none) → false;
   (false, .ready(builds: ["11.15-wine"])) → false; (false, .unpatched(...)) → false */ }

@Test("requestWineDownload asks first and downloads nothing")
func requestAsks() { /* pendingConfirmation == .downloadWine; no run started */ }
```

- [ ] **Step 2: Run to verify failure**, **Step 3: Implement**, **Step 4: Run the full suite**, **Step 5: Commit**

```bash
git add app
git commit -m "Offer to download Wine from the status model"
```

### Task 7: Status pane UI and strings

**Files:**
- Modify: `Views/StatusView.swift`, `Resources/Localization/Localizable.xcstrings`
- Test: `LocalizationTests.swift` (existing), `CrossOverRowTests.swift`

**Interfaces:**
- Consumes: Task 5 rows, Task 6 requests.

- [ ] **Step 1:** In `crossOverAction`, add `.none where row.isDownloadable` → `Download & Set Up` (prominent when `snapshot.runner == .none`, enabled by `status.canInstall`) calling `status.requestWineDownload()`; `.unpatched`/`.damaged where row.isDownloadable` → `Repair` calling `requestWineDownload(replacingExisting: true)`; in `crossOverMenu` route `Reinstall` for downloadable rows the same way. Keep the "Not found" row but not red when a downloadable row is shown, with the text pointing at the free option.
- [ ] **Step 2:** Add two `confirmationDialog`s using the existing `Binding` helper at `StatusView.swift:266`. `.downloadWine`: size about 190 MB, source Gcenx's macOS Wine builds on GitHub, license LGPL, limits (Rosetta only, no D3DMetal/DXMT, media codecs need GStreamer); buttons `Download` and `Cancel`. `.installWithWine`: explains no CrossOver was found; buttons `Download Wine and Install`, `Install Without Wine` (calls `installIntoSteam()`), `Cancel`.
- [ ] **Step 3:** Add all new strings to `Localizable.xcstrings` following the existing key style.
- [ ] **Step 4: Verify**

Run: `cd app && swift build && swift test --no-parallel`
Expected: build succeeds, all tests pass including `LocalizationTests`. Then launch the built app and check the Status pane shows the Wine row with a working confirmation dialog (cancel it; do not download). Report what you saw.

- [ ] **Step 5: Commit**

```bash
git add app
git commit -m "Add the free Wine download to the status pane"
```

### Task 8: Real download, documentation and final verification

**Files:**
- Create: `app/Tests/NotProtonAppTests/RealWineTests.swift` (opt-in)
- Modify: `README.md`, `CONTRIBUTING.md`

- [ ] **Step 0: Audit `dylib/feats/compat_run.sh` for CrossOver-only assumptions.** Check each against the extracted 11.15 tree: `bin/wineserver` exists (the `wineserver-x86` fallback is already guarded by `-x`); the D3DMetal block is guarded by a file check (`lib64/apple_gptk/...`, absent in Gcenx builds); `share/wine/wine.inf` exists (line ~327); the `crossover` user alias (lines ~506-528) is harmless when the prefix has no such user; `CX_*` and `DXMT_*` env handling does not fail when unset. Guard anything that is not. Run `make scriptcheck envcheck runcheck`; expected: pass, output unchanged for CrossOver runs. List what you changed or confirmed in the commit message.
- [ ] **Step 1:** Opt-in test, skipped unless `NP_REAL_WINE=1`: run `WineFetcher.run` against the real GitHub URL into scratch `runners`/`downloads`, then `NtdllPatcher.stage` and expect every staged ntdll hash to equal the pinned `patchedNtdll`. Run it: `NP_REAL_WINE=1 swift test --no-parallel --filter RealWineTests`. Expected: PASS. If the network is blocked, say so and do not mark this done.
- [ ] **Step 2:** README: replace the "support for alternatives to CrossOver itself is not planned" paragraph with a short "Free Wine" section: what it is, how to use it from the Status pane, the limits listed in Global Constraints, and that it is a fork-only addition. CONTRIBUTING: adjust the non-goal line accordingly.
- [ ] **Step 3:** Run `make app-tests` and the repo lint (`.github/workflows/lint.yml` commands). Expected: clean.
- [ ] **Step 4: Report what is not verified.** Launching a game on this runtime (does `lsteamclient` load) needs a real Steam install and is left to the user. Say so plainly in the final report.
- [ ] **Step 5: Commit**

```bash
git add README.md CONTRIBUTING.md app/Tests dylib
git commit -m "Document the free Wine option and add the real-download test"
```

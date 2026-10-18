# GPTK Second Runtime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user who has Apple's Game Porting Toolkit 3.0-3 set it up from the Status pane, so DirectX 11 and 12 games run through D3DMetal in a second Steam compatibility tool. The free 11.15 runtime is unchanged.

**Architecture:** The GPTK runtime is a `RunnerBuild` with a user-supplied origin. It is cloned to `runners/crossover-gptk-3.0-3/CrossOver`, so the run script's existing root path works. Its line in the tool list carries a `kind` column. The run script reads that column to skip DXVK, pick the `pfx-gptk` prefix, and set the libd3dshared path. Patching, verification and bridge installs skip the runtime.

**Tech Stack:** Swift 6 and SwiftUI (app, Swift Testing), C (`dylib/feats/compat.c`, `compatcheck`), POSIX sh (`compat_run.sh`, `envcheck`).

**Spec:** `docs/superpowers/specs/2026-10-18-gptk-second-runtime-design.md`

## Global Constraints

- Tool name `notproton-gptk-3.0-3`, which starts with `notproton` so `SupportPaths.notprotonTools` finds it.
- Build id `gptk-3.0-3`, version `3.0-3`, archive `game-porting-toolkit-3.0-3.tar.xz`.
- Kinds are `crossover`, `free-wine` and `gptk`. A tool-list line with four columns has no kind, and the run script infers it as before.
- GPTK prefix is `$STEAM_COMPAT_DATA_PATH/pfx-gptk`. Free Wine and CrossOver keep `pfx`.
- The app never downloads or bundles Apple's toolkit. Personal use only. Nothing here ships.
- The `gptk` kind never runs the DXVK step. Free-runtime pins do not change.
- Every commit ends with `Claude-Session: https://claude.ai/code/session_01VBEYC4GADo2KrohCBkQMiR`.

## Rulings made before Task 1

These differ from the spec or fill gaps it left. Each one is ledgered when executed.

- **R1. Runtime path.** `runners/crossover-gptk-3.0-3/CrossOver`, not `runners/gptk-3.0-3/`. The run script's `CX_ROOT`, `RunnerStore.clonedBuilds` and `RunnerInstaller.hasClone` already use that layout. The spec's testing bullet "clonedBuilds never lists GPTK" is superseded by R2. Cost if wrong: the runtime appears in clone listings, and R2 keeps it out of verification.
- **R2. Origin gating.** A `RunnerOrigin.userSupplied` build is skipped by ntdll patching, bridge builtin install, the loader entitlement and `RunnerPatcher.verify`. The reason: `RunnerPatcher.install` copies the 11.15 bridge builtins into every installed build (the loop in `SteamInstaller`), which would put 11.15 DLLs into the 7.7 tree. Cost if wrong: a missed call site would still patch GPTK. Task 5 tests the helper that the call sites share.
- **R3. Kind column.** `kind` is a fifth tab column in tool-list lines. `CompatToolList.contents` writes it, `parse_tool_line` reads it, and `write_tool` writes a `kind` file. A four-column line is accepted with kind absent. An unknown kind value makes the line invalid, so it is skipped and never defaulted. Cost: the C parser and the Swift writer change together.
- **R4. Spike split.** Part A (no Steam, scratch only) gates Task 1. Part B (a Steam launch) is Task 9, which runs after the tool exists. Bridge work is written as a separate plan, and only if Part A or Part B shows it is needed. The spec asked for one spike before implementation, but Part B cannot run before the tool is registered. Cost if wrong: if the bridge is needed, its work follows this branch rather than preceding it.
- **R5. Version gate.** GPTK install refuses any `Info.plist` version other than `3.0-3`. Cost: a newer GPTK needs a new pin before it installs.

## Review Focus

1. A GPTK runtime never receives the 11.15 ntdll patch or the bridge DLLs. Tested in Task 5.
2. An unknown kind value on a tool-list line is refused, not defaulted to `free-wine`. Tested in Task 1 (C) and Task 2 (shell).
3. A `gptk` launch never runs the DXVK step. Tested in Task 2 (envcheck).
4. A GPTK install with a missing file or the wrong version leaves no runtime and no tool line. Tested in Task 4.
5. Removing the GPTK runtime never deletes a `pfx-gptk` prefix. Tested in Task 4.

---

### Task 0: Spike Part A (scratch only, no product code)

**Files:**
- Reference: `scratchpad/gptk-run.sh` (the probe environment that ran D3DMetal)
- Reference: the extracted GPTK tree under `scratchpad/gptk3/`

**Interfaces:**
- Consumes: nothing from the repo.
- Produces: a ledger line stating whether Megabonk reaches its first screen with no Steam running.

- [ ] **Step 1: Re-run the D3D probes through the probe environment**

Run the D3D11 and D3D12 probes through `scratchpad/gptk-run.sh` against the extracted tree.
Expected: a DX11 device at feature level 11_1 and a DX12 device at 12_0, as measured before.

- [ ] **Step 2: Run Megabonk outside Steam, with the same environment**

Find the executable under `~/Library/Application Support/Steam/steamapps/common/Megabonk/`. Run it through the probe environment with Steam not running. Record the first lines of the Wine log and whether a window appears.
Expected: either a window, or a logged failure. Both are results.

- [ ] **Step 3: Ledger the result**

Write `Task 0: Ruling: Part A <reached first screen | failed: <first error>>`. If the game does not start but the probes do, stop and report to the user before Task 1, because the failure is outside this plan.

---

### Task 1: The kind column in the tool list

**Files:**
- Modify: `app/Sources/NotProtonApp/Model/SupportedRunner.swift` (add `enum RuntimeKind`, `RunnerBuild.kind`, and `RunnerOrigin.userSupplied`)
- Modify: `app/Sources/NotProtonApp/Model/RunnerStore.swift:99` (`CompatToolList.contents` writes five columns)
- Modify: `dylib/feats/compat.c:377` (`parse_tool_line`), `:481` (`write_tool`), `:546` (`remove_tool`)
- Test: `app/Tests/NotProtonAppTests/RuntimeKindTests.swift` (new), `dylib/tests/compatcheck.c`

**Interfaces:**
- Produces: `enum RuntimeKind: String, Sendable { case crossover, freeWine = "free-wine", gptk }`. `RunnerBuild.kind` maps `.crossOver` to `.crossover`, `.downloadedWine` to `.freeWine` and `.userSupplied` to `.gptk`. `CompatToolList.contents(_:)` emits `name\tbuild\tflavor\tdisplay\tkind\n`.
- C: `tool_entry_t` gains `char kind[16]`. `write_tool` writes `<dir>/kind` when kind is set. `remove_tool` unlinks `kind`.

- [ ] **Step 1: Write the failing Swift test**

Test `freeWineLineCarriesItsKind`: the contents for a downloaded-Wine build end in `\tfree-wine\n`. Test `gptkLineCarriesItsKind` does the same for `.userSupplied`.

- [ ] **Step 2: Write the failing C test**

In `compatcheck.c`, parse a four-column line and expect an empty kind. Parse a five-column line ending `gptk` and expect `gptk`. Parse a five-column line ending `unknown` and expect rejection.

- [ ] **Step 3: Run both to verify they fail**

Run: `make compatcheck` and `make app-tests`
Expected: FAIL. The kind is missing from both.

- [ ] **Step 4: Implement the Swift side**

Add the enum, the `kind` property and the `.userSupplied` case, which Task 5 uses. Change `contents` to write the fifth column.

- [ ] **Step 5: Implement the C side**

Extend `parse_tool_line` to accept four or five fields. Validate the kind against the three values. Make `write_tool` and `remove_tool` handle the `kind` file.

- [ ] **Step 6: Run both to verify they pass**

Run: `make compatcheck` and `make app-tests`
Expected: PASS on both. Read the tail of each run.

- [ ] **Step 7: Commit**

---

### Task 2: The run script reads the kind

**Files:**
- Modify: `dylib/feats/compat_run.sh` (`np_build` read at line 150, libd3dshared branch at lines 160-161, `USER` at line 201, the `install_dxvk` gate at line 1164, `WINEPREFIX` at line 1082)
- Test: `dylib/tests/envcheck.sh` (add a "Runtime kind" section beside the DXVK section)

**Interfaces:**
- Consumes: the `kind` file written by Task 1.
- Produces: `np_kind`, one of `crossover`, `free-wine` or `gptk`. An absent file means infer from `np_stock_wine`, as now. Any other value shows the alert `NotProton runtime kind is not recognised.` and exits 1.

- [ ] **Step 1: Write the failing envcheck section**

For a tool directory with `kind` = `gptk`, expect `WINEPREFIX` to end in `pfx-gptk`, and expect `install_dxvk` to return without copying. For `free-wine`, expect the DXVK copy. For `bogus`, expect the alert and exit 1.

- [ ] **Step 2: Run to verify it fails**

Run: `make envcheck`
Expected: FAIL.

- [ ] **Step 3: Implement**

Read `np_kind` after `np_build`. Change the DXVK gate to `[ "$np_kind" = free-wine ] || return 0`. For `gptk`, set `CX_APPLEGPTK_LIBD3DSHARED_PATH` to `$CX_ROOT/lib/external/libd3dshared.dylib`, and set `WINEPREFIX` to `$STEAM_COMPAT_DATA_PATH/pfx-gptk`. Keep `USER=steamuser` for `free-wine` and `gptk`.

- [ ] **Step 4: Run to verify it passes**

Run: `make envcheck` and `make scriptcheck`
Expected: PASS on both.

- [ ] **Step 5: Commit**

---

### Task 3: Validating the GPTK runtime

**Files:**
- Create: `app/Sources/NotProtonApp/Model/GPTKRuntime.swift`
- Test: `app/Tests/NotProtonAppTests/GPTKRuntimeTests.swift` (new)

**Interfaces:**
- Produces: `enum GPTKRuntime` with `static let version = "3.0-3"`, `static let build = "gptk-3.0-3"`, `static let archiveName = "game-porting-toolkit-3.0-3.tar.xz"`, `static let requiredFiles: [String]`, `static func root(in runners: URL) -> URL` (returns `SupportPaths.clonedRoot(forBuild: build, runners: runners)`), `static func missingFiles(in wineRoot: URL) -> [String]`, and `static func archive(in downloads: URL) -> URL?`.
- `requiredFiles`, in this order: `bin/wine64`, `bin/wineserver`, `lib/wine/x86_64-windows/d3d11.dll`, `lib/wine/x86_64-windows/d3d12.dll`, `lib/wine/x86_64-windows/dxgi.dll`, `lib/wine/x86_64-unix/d3d11.so`, `lib/wine/x86_64-unix/d3d12.so`, `lib/wine/x86_64-unix/dxgi.so`, `lib/external/libd3dshared.dylib`, `lib/external/D3DMetal.framework`.

- [ ] **Step 1: Write the failing tests**

`missingFilesIsEmptyForACompleteTree`. `missingFilesNamesOnlyTheAbsentFile`, which deletes one required path and expects exactly that path. `archiveFindsTheDownloadedName`, which expects `archive(in:)` to return the file when `archiveName` is in the folder and nil otherwise. The fixture creates any path ending in `.framework` as a directory.

- [ ] **Step 2: Run to verify it fails**

Run: `make app-tests`
Expected: FAIL. `GPTKRuntime` does not exist.

- [ ] **Step 3: Implement**

Implement the three members. `missingFiles` checks each path with `FileManager.fileExists`.

- [ ] **Step 4: Run to verify it passes**

Run: `make app-tests`
Expected: PASS. Read the tail.

- [ ] **Step 5: Commit**

---

### Task 4: Installing and removing the runtime

**Files:**
- Modify: `app/Sources/NotProtonApp/Model/GPTKRuntime.swift`
- Test: `app/Tests/NotProtonAppTests/GPTKRuntimeTests.swift`

**Interfaces:**
- Consumes: Task 3, `RunnerInstaller.swapIn(staging:target:)`, `Shell.run`, `StepFailure(step:detail:)`, `DXVKLayer.run` (as the pattern to follow).
- Produces: `static func install(archive: URL, runners: URL, report: @Sendable (String) -> Void = { _ in }, sign: (URL) throws -> Void = GPTKRuntime.adHocSign) async throws` and `static func remove(runners: URL) throws`. `adHocSign` removes `com.apple.quarantine` recursively, then runs `codesign --force --deep -s -` on the wine tree, with no hardened-runtime option.

- [ ] **Step 1: Write the failing tests**

`installUnpacksAndValidates`: build a fixture `.tar.xz` with `Game Porting Toolkit.app/Contents/Info.plist` (version `3.0-3`) and `Game Porting Toolkit.app/Contents/Resources/wine` holding all required paths. Expect the runtime at `root(in:)`, `missingFiles` empty, and `sign` called once. `missingFileInstallsNothing`: drop `bin/wineserver`; expect a `StepFailure`, and no `crossover-gptk-3.0-3` directory under `runners`. `wrongVersionInstallsNothing`: plist version `3.0-2`; expect a failure. `removeKeepsPrefixes`: create `compatdata/1/pfx-gptk/marker` beside `runners`, call `remove(runners:)`, expect the marker to remain.

- [ ] **Step 2: Run to verify it fails**

Run: `make app-tests`
Expected: FAIL.

- [ ] **Step 3: Implement**

Extract to a staging directory under `runners/.gptk-extract` with `/usr/bin/tar -xf`, as `DXVKLayer.run` does. Read the plist with `NSDictionary(contentsOf:)`. Check the version (R5). Run `missingFiles` on the wine tree and throw before any swap. Create the parent `runners/crossover-gptk-3.0-3`, then call `RunnerInstaller.swapIn` into `root(in:)`. Remove the staging directory with `defer`.

- [ ] **Step 4: Run to verify it passes**

Run: `make app-tests`
Expected: PASS.

- [ ] **Step 5: Commit**

---

### Task 5: The runtime build, origin gating and its tool

**Files:**
- Modify: `app/Sources/NotProtonApp/Model/SupportedRunner.swift` (add the GPTK entry to `SupportedRunners.all`, append `"notproton-gptk-3.0-3"` to `toolPreference`, add `RunnerBuild.isPatchable`)
- Modify: `app/Sources/NotProtonApp/Model/SteamInstaller.swift:120-121` (`verifyRunner`) and `:143-145` (`patchRunner`), both filtered by `isPatchable`
- Modify: `app/Sources/NotProtonApp/Model/RunnerStore.swift`, in `state(runners:verify:)`, so verification skips builds that are not patchable
- Test: `app/Tests/NotProtonAppTests/GPTKRuntimeTests.swift`

**Interfaces:**
- Consumes: `GPTKRuntime.build`, `GPTKRuntime.version`, `RuntimeKind`.
- Produces: `RunnerBuild.isPatchable: Bool { origin != .userSupplied }`. The `SupportedRunners.all` entry follows the existing entry style, with `bundleVersion: GPTKRuntime.build`, `releaseVersion: GPTKRuntime.version`, `flavor: nil`, `loaderSHA256: ""`, empty `cleanNtdll` and `patchedNtdll`, `origin: .userSupplied`, and `tools: [CompatTool(name: "notproton-gptk-3.0-3", flavor: .rosetta, display: "NotProton GPTK 3.0")]`.

- [ ] **Step 1: Write the failing tests**

`gptkBuildIsNotDownloadable`: `SupportedRunners.downloadable` does not include it. `gptkToolIsServedOnlyWhenInstalled`: `SupportedRunners.tools(for:)` yields the GPTK tool with the gptk build and nothing without it. `unpatchedRuntimeIsReady`: a fixture clone with `lib/wine` and no bridge builtins gives `RunnerStore.state` `.ready`, not `.unpatched`. `patchableSkipsTheRuntime`: the filter used by both `SteamInstaller` loops leaves out the gptk build and keeps a crossover build.

- [ ] **Step 2: Run to verify it fails**

Run: `make app-tests`
Expected: FAIL.

- [ ] **Step 3: Implement**

Add the entry, the `toolPreference` item last, `isPatchable`, and the filter at each call site in `SteamInstaller`. Use the same filter in `RunnerStore.state`.

- [ ] **Step 4: Run to verify it passes**

Run: `make app-tests`
Expected: PASS.

- [ ] **Step 5: Commit**

---

### Task 6: Registering the tool line after install

**Files:**
- Modify: `app/Sources/NotProtonApp/Model/GPTKRuntime.swift`
- Test: `app/Tests/NotProtonAppTests/GPTKRuntimeTests.swift`

**Interfaces:**
- Consumes: `CompatToolList.installed(runners:file:)`, `CompatToolList.contents(_:)`, and the function in `RunnerStore.swift` that writes `SupportPaths.toolList` (near line 157, which calls `contents(tools)`). Reuse it. Do not write the file another way.
- Produces: `install` now also registers the tool. Steam picks the tool up on its next launch.

- [ ] **Step 1: Write the failing test**

`installRegistersTheToolLine`: after `install` with a fixture `toolList` path, the file contains `notproton-gptk-3.0-3\tgptk-3.0-3\trosetta\tNotProton GPTK 3.0\tgptk\n`.

- [ ] **Step 2: Run to verify it fails**

Run: `make app-tests`
Expected: FAIL.

- [ ] **Step 3: Implement**

Call the existing writer at the end of `install`, with the `toolList` path as a parameter that defaults to `SupportPaths.toolList`.

- [ ] **Step 4: Run to verify it passes**

Run: `make app-tests`
Expected: PASS.

- [ ] **Step 5: Commit**

---

### Task 7: The Status pane row and its actions

**Files:**
- Modify: `app/Sources/NotProtonApp/Model/GPTKRuntime.swift` (add `enum GPTKState` and `static func state(runners:) -> GPTKState`)
- Modify: `app/Sources/NotProtonApp/SystemStatus.swift` (`StatusSnapshot` gains `gptk: GPTKState`; add `setUpGPTK(archive:)` and `removeGPTK()`, each using `perform(from:)`)
- Modify: `app/Sources/NotProtonApp/Views/StatusView.swift` (the row, its detail, its buttons, and the dialog copy)
- Modify: `app/Sources/NotProtonApp/Resources/Localization/Localizable.xcstrings` (new English strings, with Italian and Simplified Chinese values, following the DXVK entries)
- Test: `app/Tests/NotProtonAppTests/GPTKRuntimeTests.swift`

**Interfaces:**
- Produces: `enum GPTKState: Equatable { case notSetUp, ready(version: String), problem(reason: String) }`. `GPTKRuntime.state` returns `.notSetUp` when `root(in:)` is missing, `.problem` with the first missing path when `missingFiles` is not empty, and `.ready(version:)` otherwise. `StatusView.gptkDetail(_ state: GPTKState) -> String?` is a static helper, as `directXLimitNote` is. The file picker offers `.tar.xz` files, and `archive(in:)` on the user's Downloads folder supplies the default.

- [ ] **Step 1: Write the failing tests**

`stateIsNotSetUpWithoutTheRuntime`. `stateNamesTheMissingFile`. `stateIsReadyWithEveryFile`. `gptkDetailIsNilWhenReady` and `gptkDetailNamesTheArchiveWhenNotSetUp`. Expect the detail copy to say NotProton does not download or include Apple's toolkit.

- [ ] **Step 2: Run to verify it fails**

Run: `make app-tests`
Expected: FAIL.

- [ ] **Step 3: Implement**

Add the state and the helper. Add the two actions to `SystemStatus`. Add the row to `StatusView`, following the free Wine row. Add the new strings to `Localizable.xcstrings`.

- [ ] **Step 4: Run to verify it passes**

Run: `make app-tests`
Expected: PASS.

- [ ] **Step 5: Commit**

---

### Task 8: Documentation

**Files:**
- Modify: `README.md` (the Graphics list, with a line that GPTK is user-supplied and for personal use)
- Modify: `CONTRIBUTING.md` (the non-goals line, which should say GPTK is not shipped)

- [ ] **Step 1: Edit both files**

Keep the wording to what the build does. Do not claim game compatibility.

- [ ] **Step 2: Check the diff**

Run: `git diff --stat`
Expected: only `README.md` and `CONTRIBUTING.md` changed.

- [ ] **Step 3: Commit**

---

### Task 9: Steam launch check (Part B, manual gate)

No code. This is the spike's second half, which needs the tool registered.

- [ ] **Step 1: Set up the runtime from the Status pane**

Choose `game-porting-toolkit-3.0-3.tar.xz`, wait for `ready`, and restart Steam.

- [ ] **Step 2: Launch Megabonk with the GPTK tool**

Set Megabonk's compatibility tool to "NotProton GPTK 3.0" in Steam's Properties, then launch it.
Expected: the game reaches its first screen. Record whether Steam's API initialises, from `notproton-run.log` under `$STEAM_COMPAT_DATA_PATH`.

- [ ] **Step 3: Ledger the ruling**

Write `Task 9: Ruling: bridge needed` or `Task 9: Ruling: bridge not needed`. If it is needed, stop. The bridge work is a separate plan, written after this one.

---

## Self-review

**Spec coverage.** Goal, scope and the in-scope items map to Tasks 1-8. Design section 1 (kind) is Tasks 1 and 2. Section 2 (location and validation) is Tasks 3 and 4, with R1. Section 3 (Steam tool) is Tasks 5 and 6. Section 4 (prefixes) is Task 2. Section 5 (bridge) is Task 0 and Task 9, with R4. Section 6 (launch environment) is Task 2. Section 7 (Status pane) is Task 7. Testing maps to each task's tests, and the superseded bullet is recorded as R2. Risks are covered by the documentation in Task 8, and by the spike.

**Type consistency.** `RuntimeKind` and `RunnerOrigin.userSupplied` are introduced in Task 1 and used in Task 5. `GPTKRuntime.root(in:)`, `missingFiles(in:)` and `archive(in:)` are defined in Task 3 and used in Tasks 4, 6 and 7. `GPTKState` is defined in Task 7 and used only there. `isPatchable` is defined and used in Task 5.

**Placeholders.** None remain, apart from Task 8's wording, which is deliberately left to the implementer within the stated limits, and Task 9, which is a manual gate.

**Proportion.** The plan lists signatures, file locations and test assertions. The bodies are left to the implementer, and each step names the expected result.

---

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-10-18-gptk-second-runtime.md`. Please review it. The five rulings (R1 to R5) are where it departs from the spec, so those are the first thing to check.

Two ways to run it:

- **Subagent-driven:** a fresh subagent per task, a reviewer after each one, then a whole-branch review. Most thorough, and costs a fresh context per task.
- **Native:** I run the tasks in this session, then one fresh reviewer checks the whole branch. Cheaper, and it is how the DXVK work ran.

I recommend **native**. The tasks share only a few interfaces (the kind column, `GPTKRuntime`, `isPatchable`), and this runs on a personal fork, so a mistake costs little. Tell me the approach you want, and whether the rulings stand.
